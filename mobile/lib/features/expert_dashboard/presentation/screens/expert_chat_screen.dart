import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../data/expert_repository.dart';
import '../../models/expert_models.dart';
import '../widgets/expert_common.dart';

/// `#edChatOverlay` — the expert's chat thread with one athlete. Live
/// messages from `chat_rooms/{id}/messages` ordered by `timestamp`
/// (ED:1237); sending performs the same idempotent room-merge +
/// `doc(id).set()` write the website does (ED:197-225).
///
/// Voice calling (`webrtc-call.js`) and image attachments are deliberately
/// not included here — see the Phase 4 notes in
/// docs/MIGRATION_INVENTORY.md for why they're deferred.
class ExpertChatScreen extends StatefulWidget {
  const ExpertChatScreen({
    super.key,
    required this.repository,
    required this.chatId,
    required this.expertId,
    required this.expertName,
    required this.athleteId,
    required this.athleteName,
    this.readOnly = false,
  });

  final ExpertRepository repository;
  final String chatId;
  final String expertId;
  final String expertName;
  final String athleteId;
  final String athleteName;
  final bool readOnly;

  @override
  State<ExpertChatScreen> createState() => _ExpertChatScreenState();
}

class _ExpertChatScreenState extends State<ExpertChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);
    try {
      await widget.repository.sendMessage(
        chatId: widget.chatId,
        expertId: widget.expertId,
        expertName: widget.expertName,
        athleteId: widget.athleteId,
        athleteName: widget.athleteName,
        text: text,
      );
      _input.clear();
      _scrollToBottom();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't send that message. Please try again.")),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZitlasTokens.bgStart,
      appBar: AppBar(
        backgroundColor: ZitlasTokens.bgCard,
        foregroundColor: ZitlasTokens.textPrimary,
        elevation: 0,
        titleSpacing: 0,
        title: Row(
          children: [
            EdAvatar(name: widget.athleteName, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.athleteName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: ZitlasTokens.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<ChatMessage>>(
              stream: widget.repository.watchMessages(widget.chatId),
              builder: (context, snap) {
                if (snap.hasError) {
                  return const EdErrorState(message: "Couldn't load this conversation.");
                }
                if (!snap.hasData) return const EdLoading();
                final messages = snap.data!;
                if (messages.isEmpty) {
                  return const EdEmptyState(
                    icon: '💬',
                    title: 'No messages yet',
                    subtitle: 'Send the first message to start the conversation.',
                  );
                }
                _scrollToBottom();
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                  itemCount: messages.length,
                  itemBuilder: (context, i) => _Bubble(message: messages[i]),
                );
              },
            ),
          ),
          if (widget.readOnly)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              color: ZitlasTokens.bgCardLight,
              child: const Text(
                '🔒 Personal Coaching Ended',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: ZitlasTokens.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: const BoxDecoration(
                  color: ZitlasTokens.bgCard,
                  border: Border(top: BorderSide(color: ZitlasTokens.borderSub)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        textCapitalization: TextCapitalization.sentences,
                        style: const TextStyle(
                          color: ZitlasTokens.textPrimary,
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: ZitlasTokens.bgCardLight,
                          hintText: 'Reply to user…',
                          hintStyle: const TextStyle(color: ZitlasTokens.textMuted),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: const BorderSide(color: ZitlasTokens.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: const BorderSide(color: ZitlasTokens.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: const BorderSide(color: ZitlasTokens.primary),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 44,
                      height: 44,
                      child: ElevatedButton(
                        onPressed: _sending ? null : _send,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: ZitlasTokens.primary,
                          shape: const CircleBorder(),
                          padding: EdgeInsets.zero,
                        ),
                        child: _sending
                            ? const SizedBox(
                                width: 17,
                                height: 17,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.send_rounded, size: 18, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: ZitlasTokens.border,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              message.text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: ZitlasTokens.primaryDark,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }

    final mine = message.isFromExpert;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.75,
        ),
        decoration: BoxDecoration(
          color: mine ? ZitlasTokens.primary : ZitlasTokens.bgCard,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
          border: mine ? null : Border.all(color: ZitlasTokens.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.imageUrl != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  message.imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
              if (message.text.isNotEmpty) const SizedBox(height: 6),
            ],
            if (message.text.isNotEmpty)
              Text(
                message.text,
                style: TextStyle(
                  color: mine ? Colors.white : ZitlasTokens.textPrimary,
                  fontSize: 14,
                  height: 1.35,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
