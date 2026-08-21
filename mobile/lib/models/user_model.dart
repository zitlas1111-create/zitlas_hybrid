/// Mirrors the `users/{uid}` Firestore document — the single most-shared
/// collection in the app (see docs/MIGRATION_INVENTORY.md §3). Only the
/// identity/role fields are modeled here; the large cloud-synced app-state
/// blob (goal/assessment/diet/workout/personalInfo/...) belongs to each
/// owning feature's own model once that feature is built, not here.
class UserModel {
  const UserModel({
    required this.uid,
    required this.email,
    this.name,
    this.photoUrl,
    this.role = 'user',
    this.roles = const [],
    this.expertStatus = 'none',
    this.serverRole,
  });

  /// The role as decided by `GET /api/auth/role` — `'expert'` or `'user'`.
  ///
  /// THIS IS THE ONLY TRUSTWORTHY ROLE. The fields below come from
  /// `users/{uid}`, which the client itself can write; the server derives
  /// this one from the verified Firebase token's `expert` custom claim AND
  /// `experts/{uid}.approved`, neither of which a device can forge.
  ///
  /// `null` means "not yet resolved" and is treated as a normal user.
  final String? serverRole;

  UserModel withServerRole(String? role) => UserModel(
        uid: uid,
        email: email,
        name: name,
        photoUrl: photoUrl,
        role: this.role,
        roles: roles,
        expertStatus: expertStatus,
        serverRole: role,
      );

  final String uid;
  final String email;
  final String? name;
  final String? photoUrl;

  /// Legacy single-value role (`'athlete' | 'expert'`) — kept alongside
  /// [roles] because both are still read on web; see the Firebase audit.
  final String role;
  final List<String> roles;

  /// `'none' | 'pending' | 'approved'`
  final String expertStatus;

  /// Whether this account is one of the approved experts.
  ///
  /// SERVER-DECIDED. This used to run the old `login.js` algorithm over
  /// `users/{uid}` — a document the client can write — and it counted
  /// `expert_pending` and `expertStatus == 'pending'` as EXPERT, so merely
  /// applying was enough to land in the expert dashboard. Both the website
  /// and this app now ask `GET /api/auth/role` instead.
  ///
  /// Fails CLOSED: an unresolved role is a normal user, never an expert.
  bool get isExpert => serverRole == 'expert';

  /// `'expert' | 'user'` — the same two values `GET /api/auth/role` returns.
  String get resolvedRole => isExpert ? 'expert' : 'user';

  factory UserModel.fromMap(Map<String, dynamic> map) {
    return UserModel(
      uid: map['uid'] as String,
      email: map['email'] as String? ?? '',
      name: map['name'] as String?,
      photoUrl: map['photo'] as String?,
      // Retained verbatim: `role` is an EXISTING Firestore field on live
      // documents. It is no longer trusted for authorisation, but renaming
      // or dropping it would break data already written.
      role: map['role'] as String? ?? 'user',
      roles: (map['roles'] as List?)?.cast<String>() ?? const [],
      expertStatus: map['expert_status'] as String? ?? 'none',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'email': email,
      if (name != null) 'name': name,
      if (photoUrl != null) 'photo': photoUrl,
      'role': role,
      'roles': roles,
      'expert_status': expertStatus,
    };
  }
}
