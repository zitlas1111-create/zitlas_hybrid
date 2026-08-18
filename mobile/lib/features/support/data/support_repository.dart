import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/network/api_client.dart';
import '../models/support_conversation.dart';

/// Help Center backend access.
///
/// WRITES go through `/api/support/*`, never straight to Firestore:
/// `firestore.rules` denies every client write to `support_conversations`, so
/// that an athlete cannot forge a `senderType:"support"` message into their
/// own thread or edit what support actually said. The backend appends the
/// message and emails the ZITLAS inbox in the same call.
///
/// READS are allowed for the owning athlete, so the thread is a live
/// `snapshots()` stream — a reply typed in the ZITLAS Gmail lands in the UI on
/// its own, with no polling and no pull-to-refresh.
class SupportRepository {
  SupportRepository({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    ApiClient? apiClient,
  })  : _injectedDb = firestore,
        _auth = auth ?? FirebaseAuth.instance,
        _api = apiClient ?? ApiClient() {
    _api.authTokenProvider = () async {
      // A token we cannot obtain degrades to "send none" so the backend
      // answers 401 and the UI shows a real authentication failure, rather
      // than throwing before the request is even attempted.
      try {
        return await _auth.currentUser?.getIdToken();
      } catch (_) {
        return null;
      }
    };
  }

  // Resolved lazily rather than in the initialiser list. Touching
  // FirebaseFirestore.instance at construction time makes this class
  // unusable anywhere Firebase is not initialised — including plain unit
  // tests of the request body, which need no database at all.
  final FirebaseFirestore? _injectedDb;
  FirebaseFirestore get _db => _injectedDb ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final ApiClient _api;

  static const collection = 'support_conversations';

  String? get _uid => _auth.currentUser?.uid;

  CollectionReference<Map<String, dynamic>> get _conversations =>
      _db.collection(collection);

  /// Live list of this athlete's conversations, most recent first.
  Stream<List<SupportConversation>> watchConversations() {
    final uid = _uid;
    if (uid == null) return Stream.value(const []);
    return _conversations
        .where('userId', isEqualTo: uid)
        .snapshots()
        .map((snap) {
      final rows = snap.docs
          .map((d) => SupportConversation.fromMap(d.id, d.data()))
          .toList();
      rows.sort((a, b) {
        final x = a.lastMessageAt, y = b.lastMessageAt;
        if (x == null && y == null) return 0;
        if (x == null) return 1;
        if (y == null) return -1;
        return y.compareTo(x);
      });
      return rows;
    });
  }

  /// Live single conversation — drives the chat header's status pill.
  Stream<SupportConversation?> watchConversation(String conversationId) {
    return _conversations.doc(conversationId).snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return null;
      return SupportConversation.fromMap(snap.id, data);
    });
  }

  /// Live thread, oldest first. Sorted client-side so no composite index is
  /// needed for a collection this small.
  Stream<List<SupportMessage>> watchMessages(String conversationId) {
    return _conversations
        .doc(conversationId)
        .collection('messages')
        .snapshots()
        .map((snap) {
      final rows = snap.docs
          .map((d) => SupportMessage.fromMap(d.id, d.data()))
          .toList();
      rows.sort((a, b) {
        final x = a.createdAt, y = b.createdAt;
        if (x == null && y == null) return 0;
        if (x == null) return -1;
        if (y == null) return 1;
        return x.compareTo(y);
      });
      return rows;
    });
  }

  /// Opens a NEW conversation. Returns its id so the caller can push straight
  /// into the thread.
  /// The exact body `POST /api/support/contact` expects.
  ///
  /// `name` and `email` are REQUIRED by the contact schema, and are taken from
  /// the signed-in Firebase user rather than asked for again — the athlete
  /// already told ZITLAS who they are by logging in, and a typed address could
  /// disagree with the account the ticket is filed against.
  ///
  /// Sending them is also what keeps this client working across a deploy: the
  /// backend currently in production requires both, so a build that omitted
  /// them answered `422 Field required; Field required`. The server still
  /// treats the verified ID token as authoritative for identity — these values
  /// are a display fallback, never an authorisation input.
  Map<String, dynamic> buildContactBody({
    required String subject,
    required String category,
    required String message,
  }) {
    final user = _auth.currentUser;
    final displayName = (user?.displayName ?? '').trim();
    final email = (user?.email ?? '').trim();
    return {
      // Never empty: the schema enforces min_length 1 on name.
      'name': displayName.isNotEmpty ? displayName : 'ZITLAS Athlete',
      'email': email,
      'subject': subject,
      'category': category,
      'message': message,
    };
  }

  Future<String> createConversation({
    required String subject,
    required String category,
    required String message,
  }) async {
    final res = await _api.post(
      '/api/support/contact',
      body: buildContactBody(
        subject: subject,
        category: category,
        message: message,
      ),
    );
    if (res is Map && res['conversationId'] != null) {
      return res['conversationId'].toString();
    }
    throw Exception('Could not start the conversation.');
  }

  /// Follow-up inside an existing conversation — never opens a new one.
  Future<void> sendReply({
    required String conversationId,
    required String message,
  }) async {
    await _api.post(
      '/api/support/conversations/$conversationId/messages',
      body: {'message': message},
    );
  }

  /// Clears this athlete's unread badge. Best-effort: failing to mark read
  /// must never block reading the thread.
  Future<void> markRead(String conversationId) async {
    try {
      await _api.post('/api/support/conversations/$conversationId/read');
    } catch (_) {
      /* non-fatal */
    }
  }

  /// REST fallback for the thread, used when the Firestore listener cannot
  /// attach (offline, or the SDK blocked). Same documents, same shapes.
  Future<List<SupportMessage>> fetchMessages(String conversationId) async {
    final res =
        await _api.get('/api/support/conversations/$conversationId/messages');
    if (res is! Map) return const [];
    final raw = (res['messages'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((m) => SupportMessage.fromMap(
            (m['id'] ?? '').toString(), m.cast<String, dynamic>()))
        .toList();
  }
}
