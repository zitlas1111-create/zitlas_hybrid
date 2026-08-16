import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/util/json_coerce.dart';

DateTime? _asDate(dynamic v) {
  if (v is Timestamp) return v.toDate();
  if (v is String) return DateTime.tryParse(v);
  return null;
}

String? _asString(dynamic v) => v is String && v.isNotEmpty ? v : null;

/// `experts/{uid}` — the single source of truth for expert identity
/// (expert-dashboard.js:5146 comment: "experts/{uid} is the single source of
/// truth. users/{uid} is only consulted for the role check").
///
/// Defaults mirror `buildExpertFromFirebase()` (ED:22-48) exactly.
class ExpertProfile {
  const ExpertProfile({
    required this.uid,
    this.name = 'Expert',
    this.email = '',
    this.specialization = 'Nutrition Expert',
    this.title = 'ZITLAS Expert',
    this.bio = 'Expert nutritionist on the ZITLAS platform.',
    this.quote = 'Every step forward is progress.',
    this.experience = 'ZITLAS Certified',
    this.sessions = '0',
    this.clients = '0',
    this.successRate = '100%',
    this.fee = 199,
    this.sessionDuration = 20,
    this.status = 'online',
    this.photo,
    this.rating = '5.0',
    this.reviewCount = 0,
    this.verified = false,
    this.approved = false,
  });

  final String uid;
  final String name;
  final String email;

  /// `specialization` (new) falling back to `speciality` (legacy) — the
  /// website reads both (ED:2519).
  final String specialization;
  final String title;
  final String bio;
  final String quote;
  final String experience;
  final String sessions;
  final String clients;
  final String successRate;

  /// `fee` on Firestore — review fee in ₹.
  final int fee;
  final int sessionDuration;

  /// `'online' | 'offline'` — the WEBSITE's manual availability flag.
  ///
  /// NOT presence, and deliberately no longer readable as such: the
  /// `isOnline => status != 'offline'` getter that used to sit below was
  /// removed because nothing ever wrote `'offline'` automatically, so it
  /// reported every expert green forever. Live presence comes from
  /// `core/presence/` (`PresenceDot` / `PresenceBuilder`). This field is
  /// round-tripped untouched purely so saving a profile from Flutter does
  /// not clear something `expert-dashboard.js` still renders.
  final String status;
  final String? photo;
  final String rating;
  final int reviewCount;

  /// Backend-only trust fields — never written by the client.
  final bool verified;
  final bool approved;

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '--';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  String get firstName => name.trim().split(RegExp(r'\s+')).first;

  factory ExpertProfile.fromMap(String uid, Map<String, dynamic> m) {
    return ExpertProfile(
      uid: uid,
      name: _asString(m['name']) ?? 'Expert',
      email: _asString(m['email']) ?? '',
      specialization:
          _asString(m['specialization']) ?? _asString(m['speciality']) ?? 'Nutrition Expert',
      title: _asString(m['title']) ?? 'ZITLAS Expert',
      bio: _asString(m['bio']) ?? 'Expert nutritionist on the ZITLAS platform.',
      quote: _asString(m['quote']) ?? 'Every step forward is progress.',
      experience: _asString(m['experience']) ?? 'ZITLAS Certified',
      sessions: m['sessions']?.toString() ?? '0',
      clients: m['clients']?.toString() ?? '0',
      successRate: m['successRate']?.toString() ?? '100%',
      fee: asInt(m['fee']) ?? 199,
      sessionDuration: asInt(m['sessionDuration']) ?? 20,
      status: _asString(m['status']) ?? 'online',
      photo: _asString(m['profilePhoto']) ?? _asString(m['photo']),
      rating: asDisplayString(m['rating']) ?? '5.0',
      reviewCount: asInt(m['reviews']) ?? 0,
      verified: m['verified'] == true,
      approved: m['approved'] == true,
    );
  }

  /// Exactly the field set `saveProfile()` writes (ED:2725-2744) —
  /// deliberately excludes `verified`/`approved`/`rating`/`reviews`, which
  /// Firestore rules reserve for the backend.
  Map<String, dynamic> toEditableMap() {
    return {
      'name': name,
      'specialization': specialization,
      'title': title,
      'bio': bio,
      'quote': quote,
      'experience': experience,
      'sessions': sessions,
      'clients': clients,
      'successRate': successRate,
      'fee': fee,
      'sessionDuration': sessionDuration,
      'status': status,
      'updatedAt': DateTime.now().toIso8601String(),
    };
  }

  ExpertProfile copyWith({
    String? name,
    String? specialization,
    String? title,
    String? bio,
    String? quote,
    String? experience,
    String? sessions,
    String? clients,
    String? successRate,
    int? fee,
    int? sessionDuration,
    String? status,
  }) {
    return ExpertProfile(
      uid: uid,
      name: name ?? this.name,
      email: email,
      specialization: specialization ?? this.specialization,
      title: title ?? this.title,
      bio: bio ?? this.bio,
      quote: quote ?? this.quote,
      experience: experience ?? this.experience,
      sessions: sessions ?? this.sessions,
      clients: clients ?? this.clients,
      successRate: successRate ?? this.successRate,
      fee: fee ?? this.fee,
      sessionDuration: sessionDuration ?? this.sessionDuration,
      status: status ?? this.status,
      photo: photo,
      rating: rating,
      reviewCount: reviewCount,
      verified: verified,
      approved: approved,
    );
  }
}

/// Canonical review statuses — `_normalizeStatus()` (ED:123-140). Legacy
/// values are migrated on read exactly as the website does.
abstract final class ReviewStatus {
  static const pending = 'pending';
  static const inProgress = 'in_progress';
  static const reviewCompleted = 'review_completed';
  static const rejected = 'rejected';

  static String normalize(String? raw) {
    switch (raw) {
      case 'accepted':
      case 'expert_reviewing':
        return inProgress;
      case 'completed':
      case 'reviewed':
        return reviewCompleted;
      case null:
      case '':
        return pending;
      default:
        return raw;
    }
  }
}

/// `review_requests` doc where `expertId == uid`.
class ReviewRequest {
  const ReviewRequest({
    required this.id,
    required this.status,
    this.userId,
    this.athleteName,
    this.reviewType = 'diet',
    this.totalPrice,
    this.isPremium = false,
    this.paymentStatus,
    this.bundleRole,
    this.siblingId,
    this.chatId,
    this.serviceType,
    this.createdAt,
  });

  final String id;

  /// Already normalized via [ReviewStatus.normalize].
  final String status;
  final String? userId;
  final String? athleteName;

  /// `'diet' | 'workout' | 'chat_only'`
  final String reviewType;
  final num? totalPrice;
  final bool isPremium;
  final String? paymentStatus;

  /// `'secondary'` means this review is bundled behind a primary one.
  final String? bundleRole;
  final String? siblingId;
  final String? chatId;
  final String? serviceType;
  final DateTime? createdAt;

  bool get isChatOnly => reviewType == 'chat_only';
  bool get isBundledSecondary => bundleRole == 'secondary';
  bool get awaitingPayment => paymentStatus == 'awaiting_payment';

  String get displayName => athleteName ?? 'Athlete';

  /// `_prBuildInboxCard()` type labels (ED:4620-4624).
  String get typeLabel {
    switch (reviewType) {
      case 'workout':
        return '💪 Workout Plan Review';
      case 'chat_only':
        return '💬 Chat Consultation';
      default:
        return '🥗 Diet Plan Review';
    }
  }

  /// `chatIncluded` in `_prAcceptReview` (ED:4699).
  bool get chatIncluded =>
      serviceType == null || serviceType == 'chat' || serviceType == 'verification_chat';

  factory ReviewRequest.fromMap(String id, Map<String, dynamic> m) {
    return ReviewRequest(
      id: id,
      status: ReviewStatus.normalize(m['status'] as String?),
      userId: _asString(m['userId']),
      athleteName: _asString(m['athleteName']) ?? _asString(m['userName']),
      reviewType: _asString(m['reviewType']) ?? _asString(m['planReviewType']) ?? 'diet',
      totalPrice: asNum(m['totalPrice']),
      isPremium: m['isPremium'] == true,
      paymentStatus: _asString(m['paymentStatus']),
      bundleRole: _asString(m['bundleRole']),
      siblingId: _asString(m['siblingId']),
      chatId: _asString(m['chatId']),
      serviceType: _asString(m['serviceType']),
      createdAt: _asDate(m['createdAt']) ?? _asDate(m['submittedAt']) ?? _asDate(m['acceptedAt']),
    );
  }
}

/// The athlete snapshot the backend copies onto a coaching request.
///
/// Written server-side (`_athlete_profile_summary` in
/// `backend/routes/coaching.py`) because Security Rules only let an expert
/// read `users/{athleteId}` once they are the ACTIVE coach — a pending request
/// must not grant access to the athlete's whole profile. Every field is
/// nullable: an athlete who hasn't filled in their height renders as "—", not
/// as a made-up number.
class CoachingAthleteProfile {
  const CoachingAthleteProfile({
    this.photo,
    this.gender,
    this.age,
    this.heightCm,
    this.weightKg,
    this.bmi,
    this.goalType,
  });

  final String? photo;
  final String? gender;
  final int? age;
  final num? heightCm;
  final num? weightKg;
  final num? bmi;
  final String? goalType;

  /// True when there is at least one real figure to show. Requests made
  /// before this snapshot existed have none, and the card says so rather than
  /// rendering a row of dashes.
  bool get hasAny =>
      photo != null ||
      gender != null ||
      age != null ||
      heightCm != null ||
      weightKg != null ||
      bmi != null ||
      goalType != null;

  static CoachingAthleteProfile? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    return CoachingAthleteProfile(
      photo: _asString(m['photo']),
      gender: _asString(m['gender']),
      age: asNum(m['age'])?.toInt(),
      heightCm: asNum(m['heightCm']),
      weightKg: asNum(m['weightKg']),
      bmi: asNum(m['bmi']),
      goalType: _asString(m['goalType']),
    );
  }
}

/// `personal_coach_requests` doc where `expertId == uid`.
class CoachingRequest {
  const CoachingRequest({
    required this.id,
    required this.status,
    this.requestId,
    this.athleteId,
    this.athleteName,
    this.expertId,
    this.expertName,
    this.planType,
    this.planLabel,
    this.price,
    this.isPremium = false,
    this.createdAt,
    this.athleteProfile,
  });

  final String id;

  /// `pending | active | declined | expired | completed | ended | withdrawn`
  final String status;

  /// The backend's own request identifier — this, not the Firestore doc id,
  /// is what `/api/coaching/accept|reject` expects (ED:1539).
  final String? requestId;
  final String? athleteId;
  final String? athleteName;
  final String? expertId;
  final String? expertName;
  final String? planType;
  final String? planLabel;
  final num? price;
  final bool isPremium;
  final DateTime? createdAt;

  /// Server-copied athlete snapshot — null on requests created before it
  /// existed.
  final CoachingAthleteProfile? athleteProfile;

  /// `PC_PLAN_ICONS` (ED:1434).
  String get planIcon {
    switch (planType) {
      case 'diet':
        return '🥗';
      case 'training':
        return '💪';
      case 'complete':
        return '🏆';
      default:
        return '👨‍🏫';
    }
  }

  /// `statusLine` (ED:1463-1469) — verbatim copy.
  String get statusLine {
    switch (status) {
      case 'pending':
        return '🟢 Payment Reserved — awaiting your response';
      case 'active':
        return '✅ Active coaching client';
      case 'declined':
        return '❌ Declined';
      case 'expired':
        return '⌛ Expired — reservation released';
      case 'ended':
        return 'Coaching ended by athlete';
      case 'withdrawn':
        return 'Withdrawn by athlete';
      default:
        return 'Completed';
    }
  }

  factory CoachingRequest.fromMap(String id, Map<String, dynamic> m) {
    return CoachingRequest(
      id: id,
      status: _asString(m['status']) ?? 'pending',
      requestId: _asString(m['requestId']) ?? id,
      athleteId: _asString(m['athleteId']),
      athleteName: _asString(m['athleteName']),
      expertId: _asString(m['expertId']),
      expertName: _asString(m['expertName']),
      planType: _asString(m['planType']),
      planLabel: _asString(m['planLabel']),
      price: asNum(m['price']),
      isPremium: m['isPremium'] == true,
      createdAt: _asDate(m['createdAt']),
      athleteProfile: CoachingAthleteProfile.fromMap(m['athleteProfile']),
    );
  }
}

/// `personal_coaching/{athleteUid}` doc where `coachId == uid` — an active
/// paid coaching relationship.
class CoachingRelationship {
  const CoachingRelationship({
    required this.id,
    required this.status,
    this.athleteId,
    this.athleteName,
    this.coachId,
    this.coachName,
    this.planType,
    this.planLabel,
    this.startDate,
    this.endDate,
  });

  final String id;
  final String status;
  final String? athleteId;
  final String? athleteName;
  final String? coachId;
  final String? coachName;
  final String? planType;
  final String? planLabel;
  final DateTime? startDate;
  final DateTime? endDate;

  /// `coaching-gate.js`'s canonical "is this relationship live" rule
  /// (status active AND not past its end date) — ED:1327-1331.
  bool get isActive {
    if (status != 'active') return false;
    final end = endDate;
    return end == null || end.isAfter(DateTime.now());
  }

  bool get hasEnded => status == 'ended';

  /// Returns a copy with an overridden [status]. Used for the optimistic
  /// End-Coaching refresh (cprofile.js sets `_myCoaching.status='ended'` the
  /// instant the POST returns rather than waiting for the `personal_coaching`
  /// snapshot to round-trip back). Every other field is carried over unchanged.
  CoachingRelationship copyWith({String? status}) {
    return CoachingRelationship(
      id: id,
      status: status ?? this.status,
      athleteId: athleteId,
      athleteName: athleteName,
      coachId: coachId,
      coachName: coachName,
      planType: planType,
      planLabel: planLabel,
      startDate: startDate,
      endDate: endDate,
    );
  }

  int? get daysRemaining {
    final end = endDate;
    if (end == null) return null;
    final diff = end.difference(DateTime.now()).inMilliseconds / 86400000;
    return diff.ceil();
  }

  factory CoachingRelationship.fromMap(String id, Map<String, dynamic> m) {
    return CoachingRelationship(
      id: id,
      status: _asString(m['status']) ?? '',
      athleteId: _asString(m['athleteId']) ?? id,
      athleteName: _asString(m['athleteName']),
      coachId: _asString(m['coachId']),
      coachName: _asString(m['coachName']),
      planType: _asString(m['planType']),
      planLabel: _asString(m['planLabel']),
      startDate: _asDate(m['startDate']),
      endDate: _asDate(m['endDate']),
    );
  }
}

/// `chat_rooms` doc where `participants` array-contains uid.
class ChatRoom {
  const ChatRoom({
    required this.id,
    this.athleteId,
    this.athleteName,
    this.expertId,
    this.expertName,
    this.lastMessage,
    this.lastMessageAt,
  });

  final String id;
  final String? athleteId;
  final String? athleteName;
  final String? expertId;
  final String? expertName;
  final String? lastMessage;
  final DateTime? lastMessageAt;

  String get displayName => athleteName ?? 'Athlete';

  factory ChatRoom.fromMap(String id, Map<String, dynamic> m, String myUid) {
    // Website fallback (ED:1590): derive athleteId from the doc id when the
    // field is absent — `chat_<athleteId>_<expertId>`.
    var athleteId = _asString(m['athleteId']);
    if (athleteId == null && id.startsWith('chat_')) {
      final trimmed = id.substring(5);
      athleteId = trimmed.endsWith('_$myUid')
          ? trimmed.substring(0, trimmed.length - myUid.length - 1)
          : trimmed;
    }
    return ChatRoom(
      id: id,
      athleteId: athleteId,
      athleteName: _asString(m['athleteName']),
      expertId: _asString(m['expertId']),
      expertName: _asString(m['expertName']),
      lastMessage: _asString(m['lastMessage']),
      lastMessageAt: _asDate(m['lastMessageAt']) ?? _asDate(m['updatedAt']),
    );
  }
}

/// A doc in `chat_rooms/{id}/messages`. Shape matches
/// `chatSaveExpertReply()` (ED:159-180).
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderType,
    this.text = '',
    this.type = 'text',
    this.imageUrl,
    this.timestamp,
  });

  final String id;

  /// `'expert' | 'athlete' | 'system'`
  final String senderType;
  final String text;

  /// `'text' | 'image' | 'review_packet' | 'review_complete'`
  final String type;
  final String? imageUrl;
  final DateTime? timestamp;

  bool get isFromExpert => senderType == 'expert';
  bool get isSystem => senderType == 'system';

  factory ChatMessage.fromMap(String id, Map<String, dynamic> m) {
    return ChatMessage(
      id: id,
      senderType: _asString(m['senderType']) ?? 'athlete',
      text: _asString(m['text']) ?? '',
      type: _asString(m['type']) ?? 'text',
      imageUrl: _asString(m['imageUrl']),
      timestamp: _asDate(m['timestamp']),
    );
  }
}

/// `expert_certificates` doc where `expertId == uid`.
class ExpertCertificate {
  const ExpertCertificate({
    required this.id,
    this.certificateName,
    this.issuingOrganization,
    this.certificateNumber,
    this.issuedDate,
    this.expiryDate,
    this.verificationScore,
    this.verificationStatus = 'pending_review',
    this.rejectionReason,
    this.certificateUrl,
    this.uploadedAt,
  });

  final String id;
  final String? certificateName;
  final String? issuingOrganization;
  final String? certificateNumber;
  final String? issuedDate;
  final String? expiryDate;
  final num? verificationScore;

  /// `verified | pending_review | rejected`
  final String verificationStatus;
  final String? rejectionReason;
  final String? certificateUrl;
  final DateTime? uploadedAt;

  /// `CERT_STATUS_LABEL` (ED:2897).
  String get statusLabel {
    switch (verificationStatus) {
      case 'verified':
        return '✓ AI Passed';
      case 'rejected':
        return '✕ Rejected';
      default:
        return '⏳ Manual Review Required';
    }
  }

  factory ExpertCertificate.fromMap(String id, Map<String, dynamic> m) {
    return ExpertCertificate(
      id: id,
      certificateName: _asString(m['certificateName']),
      issuingOrganization: _asString(m['issuingOrganization']),
      certificateNumber: _asString(m['certificateNumber']),
      issuedDate: _asString(m['issuedDate']),
      expiryDate: _asString(m['expiryDate']),
      verificationScore: asNum(m['verificationScore']),
      verificationStatus: _asString(m['verificationStatus']) ?? 'pending_review',
      rejectionReason: _asString(m['rejectionReason']),
      certificateUrl: _asString(m['certificateUrl']),
      uploadedAt: _asDate(m['uploadedAt']),
    );
  }
}
