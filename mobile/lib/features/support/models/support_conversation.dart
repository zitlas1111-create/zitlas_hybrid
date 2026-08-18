/// Help Center data model — mirrors `support_conversations/{id}` and its
/// `messages` subcollection exactly as `backend/services/support_service.py`
/// writes them. Both this app and the website read the SAME documents, so a
/// field renamed here must be renamed there too.
library;

/// Conversation status, matching support_service's status machine.
enum SupportStatus {
  open,
  inProgress,
  waitingForUser,
  waitingForSupport,
  resolved;

  static SupportStatus fromWire(String? raw) {
    switch ((raw ?? '').toUpperCase()) {
      case 'IN_PROGRESS':
        return SupportStatus.inProgress;
      case 'WAITING_FOR_USER':
        return SupportStatus.waitingForUser;
      case 'WAITING_FOR_SUPPORT':
        return SupportStatus.waitingForSupport;
      case 'RESOLVED':
        return SupportStatus.resolved;
      default:
        return SupportStatus.open;
    }
  }

  /// Athlete-facing wording. The raw values are support-team vocabulary
  /// ("WAITING_FOR_USER" means *we* answered), so they are deliberately not
  /// shown verbatim.
  String get label {
    switch (this) {
      case SupportStatus.inProgress:
        return 'In progress';
      case SupportStatus.waitingForUser:
        return 'ZITLAS replied';
      case SupportStatus.waitingForSupport:
        return 'Awaiting ZITLAS';
      case SupportStatus.resolved:
        return 'Resolved';
      case SupportStatus.open:
        return 'Open';
    }
  }
}

class SupportConversation {
  const SupportConversation({
    required this.id,
    required this.subject,
    required this.status,
    this.category = '',
    this.lastMessageText = '',
    this.lastMessageBy = '',
    this.lastMessageAt,
    this.unreadByUser = 0,
  });

  final String id;
  final String subject;
  final SupportStatus status;
  final String category;
  final String lastMessageText;
  final String lastMessageBy;
  final DateTime? lastMessageAt;
  final int unreadByUser;

  bool get hasUnread => unreadByUser > 0;
  bool get lastFromSupport => lastMessageBy == 'support';

  static DateTime? _date(dynamic v) {
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v)?.toLocal();
    return null;
  }

  factory SupportConversation.fromMap(String id, Map<String, dynamic> m) {
    return SupportConversation(
      id: id,
      subject: (m['subject'] ?? 'Support request').toString(),
      status: SupportStatus.fromWire(m['status']?.toString()),
      category: (m['category'] ?? '').toString(),
      lastMessageText: (m['lastMessageText'] ?? '').toString(),
      lastMessageBy: (m['lastMessageBy'] ?? '').toString(),
      lastMessageAt: _date(m['lastMessageAt']),
      unreadByUser: (m['unreadByUser'] as num?)?.toInt() ?? 0,
    );
  }
}

class SupportMessage {
  const SupportMessage({
    required this.id,
    required this.senderType,
    required this.message,
    this.createdAt,
    this.readByUser = false,
  });

  final String id;
  final String senderType; // "user" | "support"
  final String message;
  final DateTime? createdAt;
  final bool readByUser;

  bool get isFromUser => senderType == 'user';
  bool get isFromSupport => senderType == 'support';

  factory SupportMessage.fromMap(String id, Map<String, dynamic> m) {
    return SupportMessage(
      id: id,
      senderType: (m['senderType'] ?? 'user').toString(),
      message: (m['message'] ?? '').toString(),
      createdAt: SupportConversation._date(m['createdAt']),
      readByUser: m['readByUser'] == true,
    );
  }
}
