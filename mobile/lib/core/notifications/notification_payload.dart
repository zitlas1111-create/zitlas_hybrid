import 'dart:convert';

/// The deep-link intent carried by an FCM `data` payload.
///
/// One parsed shape shared by every entry point — foreground display, a
/// notification tap while backgrounded, and a cold start from
/// `getInitialMessage()` — so all three route through identical logic
/// (`NotificationRouter`) instead of each re-reading raw maps.
///
/// Field names match exactly what `backend/services/notification_service.py`
/// puts on the wire (all FCM data values are strings).
class NotificationPayload {
  const NotificationPayload({
    required this.type,
    this.chatId,
    this.senderId,
    this.senderName,
    this.mealId,
    this.coachingId,
    this.coachId,
    this.athleteId,
    this.action,
    this.actionId,
    this.notificationId,
    this.recipientRole,
    this.counterpartId,
  });

  final String type;
  final String? chatId;
  final String? senderId;
  final String? senderName;
  final String? mealId;
  final String? coachingId;
  final String? coachId;
  final String? athleteId;

  /// 'athlete' | 'coach' — which side of the relationship THIS device's user is
  /// on, derived server-side (see routes/notifications.py notify_chat). The
  /// same chat message routes to different destinations for each, so this is
  /// never guessed on the client.
  final String? recipientRole;

  /// The other party's uid: an user's coach, or a coach's athlete.
  final String? counterpartId;

  /// The website's own `navigateForAction()` key (`diet`, `training`,
  /// `expert_dashboard`, `coaching_workspace`…). Used as the fallback when
  /// [type] alone is not specific enough — the notification-centre documents
  /// have carried these long before push existed, so honouring them keeps
  /// server-sent pushes and in-app taps landing on the same screen.
  final String? action;
  final String? actionId;
  final String? notificationId;

  static String? _s(Map<String, dynamic> m, String k) {
    final v = m[k];
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty || s == 'null' ? null : s;
  }

  factory NotificationPayload.fromData(Map<String, dynamic> data) {
    return NotificationPayload(
      type: _s(data, 'type') ?? 'general',
      chatId: _s(data, 'chatId'),
      senderId: _s(data, 'senderId'),
      senderName: _s(data, 'senderName'),
      mealId: _s(data, 'mealId'),
      coachingId: _s(data, 'coachingId'),
      coachId: _s(data, 'coachId'),
      athleteId: _s(data, 'athleteId'),
      action: _s(data, 'action'),
      actionId: _s(data, 'actionId'),
      notificationId: _s(data, 'notificationId'),
      recipientRole: _s(data, 'recipientRole'),
      counterpartId: _s(data, 'counterpartId'),
    );
  }

  Map<String, dynamic> toMap() => {
        'type': type,
        if (chatId != null) 'chatId': chatId,
        if (senderId != null) 'senderId': senderId,
        if (senderName != null) 'senderName': senderName,
        if (mealId != null) 'mealId': mealId,
        if (coachingId != null) 'coachingId': coachingId,
        if (coachId != null) 'coachId': coachId,
        if (athleteId != null) 'athleteId': athleteId,
        if (action != null) 'action': action,
        if (actionId != null) 'actionId': actionId,
        if (notificationId != null) 'notificationId': notificationId,
        if (recipientRole != null) 'recipientRole': recipientRole,
        if (counterpartId != null) 'counterpartId': counterpartId,
      };

  /// Round-trips through the local-notification `payload` string, which is the
  /// only channel flutter_local_notifications gives us to carry data from a
  /// foreground-displayed notification to its tap handler.
  String encode() => jsonEncode(toMap());

  static NotificationPayload? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return NotificationPayload.fromData(decoded.cast<String, dynamic>());
      }
    } catch (_) {}
    return null;
  }

  @override
  String toString() => 'NotificationPayload(${toMap()})';
}
