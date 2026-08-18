import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/support/models/support_conversation.dart';

/// Help Center — the Flutter half of the support loop.
///
/// The wire shapes asserted here are exactly what
/// `backend/services/support_service.py` writes into
/// `support_conversations/{id}` and its `messages` subcollection. The website
/// reads those same documents, so a drift between the two clients would show
/// up as one of these tests failing.
void main() {
  group('SupportConversation.fromMap — the wire shape the backend writes', () {
    test('parses a conversation the athlete has an unread reply in', () {
      final conv = SupportConversation.fromMap('conv_abc', {
        'userId': 'athlete_1',
        'userName': 'Test Athlete',
        'userEmail': 'athlete@example.com',
        'subject': 'Diet plan help',
        'category': 'Diet',
        'status': 'WAITING_FOR_USER',
        'lastMessageText': 'Hello, we received your request.',
        'lastMessageBy': 'support',
        'lastMessageAt': '2026-08-18T10:30:00+00:00',
        'unreadByUser': 2,
      });

      expect(conv.id, 'conv_abc');
      expect(conv.subject, 'Diet plan help');
      expect(conv.status, SupportStatus.waitingForUser);
      expect(conv.hasUnread, isTrue);
      expect(conv.unreadByUser, 2);
      expect(conv.lastFromSupport, isTrue);
      expect(conv.lastMessageAt, isNotNull);
    });

    test('an unknown or missing status degrades to OPEN, never to null', () {
      expect(SupportConversation.fromMap('c', {}).status, SupportStatus.open);
      expect(
        SupportConversation.fromMap('c', {'status': 'SOMETHING_NEW'}).status,
        SupportStatus.open,
      );
    });

    test('every backend status maps to a distinct enum value', () {
      const wire = {
        'OPEN': SupportStatus.open,
        'IN_PROGRESS': SupportStatus.inProgress,
        'WAITING_FOR_USER': SupportStatus.waitingForUser,
        'WAITING_FOR_SUPPORT': SupportStatus.waitingForSupport,
        'RESOLVED': SupportStatus.resolved,
      };
      wire.forEach((raw, expected) {
        expect(SupportStatus.fromWire(raw), expected, reason: raw);
      });
    });

    test('status labels are athlete-facing, not support-team vocabulary', () {
      // "WAITING_FOR_USER" means SUPPORT answered — showing it verbatim would
      // read to the athlete as if they were the ones holding things up.
      expect(SupportStatus.waitingForUser.label, 'ZITLAS replied');
      expect(SupportStatus.waitingForSupport.label, 'Awaiting ZITLAS');
    });

    test('a conversation with no messages yet is not marked unread', () {
      final conv = SupportConversation.fromMap('c', {
        'subject': 'New',
        'status': 'WAITING_FOR_SUPPORT',
        'unreadByUser': 0,
      });
      expect(conv.hasUnread, isFalse);
      expect(conv.lastFromSupport, isFalse);
    });
  });

  group('SupportMessage.fromMap — bubble sidedness', () {
    test('a user message renders on the athlete side', () {
      final m = SupportMessage.fromMap('m1', {
        'senderType': 'user',
        'senderId': 'athlete_1',
        'message': 'Hello, I need help with my diet plan.',
        'createdAt': '2026-08-18T10:00:00+00:00',
        'readByUser': true,
      });
      expect(m.isFromUser, isTrue);
      expect(m.isFromSupport, isFalse);
      expect(m.message, 'Hello, I need help with my diet plan.');
      expect(m.createdAt, isNotNull);
    });

    test('a support message renders on the ZITLAS side and starts unread', () {
      final m = SupportMessage.fromMap('m2', {
        'senderType': 'support',
        'senderId': 'zitlas_support',
        'message': 'We will help you shortly.',
        'createdAt': '2026-08-18T10:30:00+00:00',
        'readByUser': false,
      });
      expect(m.isFromSupport, isTrue);
      expect(m.isFromUser, isFalse);
      expect(m.readByUser, isFalse);
    });

    test('a malformed timestamp yields null rather than throwing', () {
      final m = SupportMessage.fromMap('m3', {
        'senderType': 'support',
        'message': 'x',
        'createdAt': 'not-a-date',
      });
      expect(m.createdAt, isNull);
    });
  });

}
