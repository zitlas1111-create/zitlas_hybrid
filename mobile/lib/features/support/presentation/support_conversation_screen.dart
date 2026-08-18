import 'package:flutter/material.dart';

import '../../../core/theme/zitlas_tokens.dart';
import '../data/support_repository.dart';
import '../models/support_conversation.dart';

/// One Help Center thread, chat-style.
///
/// The message list is a live Firestore stream, so a support reply typed in
/// the ZITLAS Gmail appears here by itself — the athlete never has to open
/// their own email to see it.
class SupportConversationScreen extends StatefulWidget {
  const SupportConversationScreen({
    super.key,
    required this.conversationId,
    this.repository,
    this.initialSubject = '',
  });

  final String conversationId;
  final SupportRepository? repository;
  final String initialSubject;

  @override
  State<SupportConversationScreen> createState() =>
      _SupportConversationScreenState();
}

class _SupportConversationScreenState extends State<SupportConversationScreen> {
  late final SupportRepository _repo = widget.repository ?? SupportRepository();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Opening the thread IS reading it.
    _repo.markRead(widget.conversationId);
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);
    try {
      await _repo.sendReply(
          conversationId: widget.conversationId, message: text);
      _input.clear();
      _scrollToBottom();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not send. Please try again.')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZitlasTokens.bgPrimary,
      appBar: AppBar(
        backgroundColor: ZitlasTokens.bgPrimary,
        elevation: 0,
        foregroundColor: ZitlasTokens.textPrimary,
        title: StreamBuilder<SupportConversation?>(
          stream: _repo.watchConversation(widget.conversationId),
          builder: (context, snap) {
            final conv = snap.data;
            final subject = conv?.subject ?? widget.initialSubject;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  subject.isEmpty ? 'Support' : subject,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
                if (conv != null)
                  Text(
                    conv.status.label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: conv.status == SupportStatus.waitingForUser
                          ? ZitlasTokens.primary
                          : ZitlasTokens.textSecondary,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: StreamBuilder<List<SupportMessage>>(
                stream: _repo.watchMessages(widget.conversationId),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final messages = snap.data ?? const <SupportMessage>[];
                  if (messages.isEmpty) {
                    return const Center(
                      child: Text('No messages yet.',
                          style: TextStyle(color: ZitlasTokens.textSecondary)),
                    );
                  }
                  _scrollToBottom();
                  return ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                    itemCount: messages.length,
                    itemBuilder: (context, i) => _Bubble(message: messages[i]),
                  );
                },
              ),
            ),
            _composer(),
          ],
        ),
      ),
    );
  }

  Widget _composer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: ZitlasTokens.bgCard,
        border: Border(top: BorderSide(color: ZitlasTokens.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 5,
              maxLength: 5000,
              textCapitalization: TextCapitalization.sentences,
              // Stated locally, for the same reason as the Help Center form:
              // the app theme is Brightness.dark, so an unstyled field renders
              // WHITE typed text on this white composer surface.
              style: const TextStyle(
                  color: ZitlasTokens.textPrimary, fontSize: 14),
              cursorColor: ZitlasTokens.textPrimary,
              decoration: InputDecoration(
                hintText: 'Write a reply…',
                hintStyle: const TextStyle(
                    color: ZitlasTokens.textMuted, fontSize: 14),
                counterText: '',
                filled: true,
                fillColor: ZitlasTokens.bgPrimary,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: ZitlasTokens.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: ZitlasTokens.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: ZitlasTokens.primary),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 44,
            height: 44,
            child: Material(
              color: ZitlasTokens.primary,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _sending ? null : _send,
                child: _sending
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send_rounded,
                        color: Colors.white, size: 19),
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
  final SupportMessage message;

  String _time(DateTime? d) {
    if (d == null) return '';
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final mine = message.isFromUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!mine)
            const Padding(
              padding: EdgeInsets.only(bottom: 4, left: 2),
              child: Text(
                'ZITLAS SUPPORT',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color: ZitlasTokens.primary,
                ),
              ),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: mine ? ZitlasTokens.primary : ZitlasTokens.bgCard,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(mine ? 16 : 5),
                  bottomRight: Radius.circular(mine ? 5 : 16),
                ),
                border: mine
                    ? null
                    : Border.all(color: ZitlasTokens.border),
              ),
              child: Text(
                message.message,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: mine ? Colors.white : ZitlasTokens.textPrimary,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2, right: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_time(message.createdAt),
                    style: const TextStyle(
                        fontSize: 10.5, color: ZitlasTokens.textMuted)),
                if (mine) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.check_rounded,
                      size: 12, color: ZitlasTokens.primary),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
