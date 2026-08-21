import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../expert_dashboard_controller.dart';
import '../../models/expert_models.dart';
import '../widgets/expert_common.dart';

/// `#sectionChats` — the live client-chat list backed by
/// `chat_rooms where participants array-contains uid` (ED:1582).
class ExpertChatsSection extends StatelessWidget {
  const ExpertChatsSection({super.key, required this.onOpenRoom});

  final void Function(ChatRoom) onOpenRoom;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ExpertDashboardController>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        const EdSectionLabel('Client Chats'),
        if (c.chatsLoading)
          const EdLoading()
        else if (c.chatsError != null)
          ZitlasCard(
            child: EdErrorState(message: edErrorMessage(c.chatsError, what: 'your chats')),
          )
        else if (c.chatRooms.isEmpty)
          const ZitlasCard(
            padding: EdgeInsets.zero,
            child: EdEmptyState(
              icon: '💬',
              title: 'No Active Chats',
              subtitle: 'Chats with users requesting reviews will appear here.',
            ),
          )
        else
          ZitlasCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < c.chatRooms.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, color: ZitlasTokens.borderSub, indent: 16),
                  _ChatTile(
                    room: c.chatRooms[i],
                    readOnly: c.isChatReadOnly(c.chatRooms[i].athleteId),
                    onTap: () => onOpenRoom(c.chatRooms[i]),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.room, required this.readOnly, required this.onTap});

  final ChatRoom room;
  final bool readOnly;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final when = room.lastMessageAt;
    final stamp = when == null
        ? ''
        : (DateTime.now().difference(when).inDays == 0
            ? DateFormat('HH:mm').format(when)
            : DateFormat('d MMM').format(when));

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            EdAvatar(name: room.displayName, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          room.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: ZitlasTokens.textPrimary,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (stamp.isNotEmpty)
                        Text(
                          stamp,
                          style: const TextStyle(
                            color: ZitlasTokens.textMuted,
                            fontSize: 10.5,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    readOnly
                        ? '🔒 Personal Coaching Ended'
                        : (room.lastMessage ?? 'Client Chat'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: ZitlasTokens.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
