import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../../core/network/api_exception.dart';
import '../../../support/data/support_repository.dart';
import '../../../support/models/support_conversation.dart';
import '../../../support/presentation/support_conversation_screen.dart';

const _categories = [
  'Technical Issue',
  'Training Plan Issue',
  'Nutrition Plan Issue',
  'Account Problem',
  'Subscription',
  'Feature Request',
  'Other',
];

/// Help Center — the athlete's support inbox.
///
/// This used to be a one-way contact form: it POSTed to
/// `/api/support/contact`, showed "sent", and kept nothing. There was no way
/// to see a reply in the app at all. It is now a conversation list backed by
/// `support_conversations`, the same documents the website reads, with a live
/// stream so a reply typed in the ZITLAS Gmail shows up on its own.
class HelpSupportScreen extends StatefulWidget {
  const HelpSupportScreen({super.key, this.repository, this.initialConversationId});

  final SupportRepository? repository;

  /// Set when arriving from a `support_reply` push, so the notification opens
  /// the exact thread instead of the list.
  final String? initialConversationId;

  @override
  State<HelpSupportScreen> createState() => _HelpSupportScreenState();
}

class _HelpSupportScreenState extends State<HelpSupportScreen> {
  late final SupportRepository _repo = widget.repository ?? SupportRepository();

  @override
  void initState() {
    super.initState();
    final deepLink = widget.initialConversationId;
    if (deepLink != null && deepLink.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openThread(deepLink, ''));
    }
  }

  void _openThread(String id, String subject) {
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SupportConversationScreen(
        conversationId: id,
        repository: _repo,
        initialSubject: subject,
      ),
    ));
  }

  Future<void> _startNew() async {
    final created = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NewConversationSheet(repository: _repo),
    );
    // A non-null id can only come back from a 2xx, and the backend reserves
    // 2xx for mail the support inbox has actually accepted — so this
    // confirmation can never be shown for an undelivered message.
    if (created != null && created.isNotEmpty && mounted) {
      await _showSentConfirmation();
      if (mounted) _openThread(created, '');
    }
  }

  Future<void> _showSentConfirmation() {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: ZitlasTokens.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: const BoxDecoration(
                color: ZitlasTokens.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_rounded,
                  color: Colors.white, size: 32),
            ),
            const SizedBox(height: 18),
            const Text(
              'Message sent successfully',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17.5,
                fontWeight: FontWeight.w800,
                color: ZitlasTokens.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Thank you for contacting ZITLAS. Please give us a little time '
              '\u2014 our team will get back to you right here in the Help '
              'Center.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.6,
                color: ZitlasTokens.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('View conversation',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: ZitlasTokens.primary)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZitlasTokens.bgPrimary,
      appBar: AppBar(
        backgroundColor: ZitlasTokens.bgPrimary,
        elevation: 0,
        foregroundColor: ZitlasTokens.textPrimary,
        title: const Text('Help & Support',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: ZitlasTokens.primary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _startNew,
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('New Conversation',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ),
            Expanded(
              child: StreamBuilder<List<SupportConversation>>(
                stream: _repo.watchConversations(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final rows = snap.data ?? const <SupportConversation>[];
                  if (rows.isEmpty) return const _EmptyState();
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, i) => _ConversationTile(
                      conversation: rows[i],
                      onTap: () => _openThread(rows[i].id, rows[i].subject),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.support_agent_rounded,
                size: 46, color: ZitlasTokens.textMuted),
            SizedBox(height: 12),
            Text('No conversations yet.',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: ZitlasTokens.textPrimary)),
            SizedBox(height: 4),
            Text('Start one and Team ZITLAS will reply right here.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 13, color: ZitlasTokens.textSecondary)),
          ],
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conversation, required this.onTap});

  final SupportConversation conversation;
  final VoidCallback onTap;

  String _when(DateTime? d) {
    if (d == null) return '';
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return '${d.hour.toString().padLeft(2, '0')}:'
          '${d.minute.toString().padLeft(2, '0')}';
    }
    return '${d.day}/${d.month}';
  }

  @override
  Widget build(BuildContext context) {
    final unread = conversation.hasUnread;
    final replied = conversation.status == SupportStatus.waitingForUser;

    return Material(
      color: unread ? ZitlasTokens.bgCardLight : ZitlasTokens.bgCard,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: unread ? ZitlasTokens.primary : ZitlasTokens.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      conversation.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: ZitlasTokens.textPrimary),
                    ),
                  ),
                  if (unread)
                    Container(
                      constraints: const BoxConstraints(minWidth: 20),
                      height: 20,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: ZitlasTokens.primary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text('${conversation.unreadByUser}',
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: Colors.white)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (conversation.lastFromSupport)
                    const Text('ZITLAS · ',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: ZitlasTokens.primary)),
                  Expanded(
                    child: Text(
                      conversation.lastMessageText.isEmpty
                          ? 'No messages yet'
                          : conversation.lastMessageText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          color: ZitlasTokens.textSecondary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: replied
                              ? ZitlasTokens.primary
                              : ZitlasTokens.border),
                    ),
                    child: Text(
                      conversation.status.label.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                        color: replied
                            ? ZitlasTokens.primary
                            : ZitlasTokens.textSecondary,
                      ),
                    ),
                  ),
                  Text(_when(conversation.lastMessageAt),
                      style: const TextStyle(
                          fontSize: 11.5, color: ZitlasTokens.textMuted)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// New-conversation composer. Subject + category + message, matching the
/// website form. Name/email are no longer collected — the backend takes both
/// from the verified Firebase token, so a typo can no longer detach a ticket
/// from its account.
class _NewConversationSheet extends StatefulWidget {
  const _NewConversationSheet({required this.repository});
  final SupportRepository repository;

  @override
  State<_NewConversationSheet> createState() => _NewConversationSheetState();
}

class _NewConversationSheetState extends State<_NewConversationSheet> {
  final _subject = TextEditingController();
  final _message = TextEditingController();
  String? _category;
  String? _subjectErr, _categoryErr, _messageErr;
  bool _sending = false;

  @override
  void dispose() {
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  bool _validate() {
    setState(() {
      _subjectErr = _subject.text.trim().isEmpty ? 'Subject is required.' : null;
      _categoryErr = _category == null ? 'Please choose a category.' : null;
      _messageErr = _message.text.trim().isEmpty ? 'Message is required.' : null;
    });
    return _subjectErr == null && _categoryErr == null && _messageErr == null;
  }

  Future<void> _submit() async {
    // `_sending` is the duplicate-submit guard: the button is disabled while a
    // send is in flight, but a queued tap can still arrive before that paints,
    // and a resend now means a genuinely duplicated support ticket.
    if (!_validate() || _sending) return;
    setState(() => _sending = true);
    try {
      final id = await widget.repository.createConversation(
        subject: _subject.text.trim(),
        category: _category!,
        message: _message.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(id);
    } catch (e) {
      if (mounted) {
        // Stay on the sheet with the text intact so a retry costs no retyping.
        setState(() => _sending = false);
        _showSendFailure(_friendlyError(e));
      }
    }
  }

  /// A failure needs room to explain itself — a floating SnackBar clips a
  /// multi-line diagnosis and disappears before it can be read.
  void _showSendFailure(String details) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ZitlasTokens.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Row(
          children: [
            Icon(Icons.error_outline_rounded,
                color: ZitlasTokens.danger, size: 22),
            SizedBox(width: 9),
            Expanded(
              child: Text('Message not sent',
                  style: TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w800,
                      color: ZitlasTokens.textPrimary)),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "We couldn't send your message. Please check the details "
                'below and try again.',
                style: TextStyle(
                    fontSize: 13.5,
                    height: 1.55,
                    color: ZitlasTokens.textSecondary),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x14E5484D),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0x40E5484D)),
                ),
                child: SelectableText(
                  details,
                  style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: ZitlasTokens.textPrimary,
                      fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: ZitlasTokens.primary)),
          ),
        ],
      ),
    );
  }

  /// The backend's own explanation beats a generic apology: a rejected
  /// credential and a dropped connection need different reactions from the
  /// athlete, and only one of them is worth retrying.
  ///
  /// Read off ApiException.body, NOT toString() — toString() is
  /// 'ApiException($statusCode): $message' and deliberately omits the body,
  /// so the FastAPI {"detail": ...} envelope is only reachable this way.
  String _friendlyError(Object e) {
    if (e is ApiException) {
      final body = e.body;
      if (body is Map) {
        final detail = body['detail'];
        // Classified delivery failures arrive as
        // {message, code, stage, hint} — show the message AND the hint, since
        // the hint is the part that says what to actually do about it.
        if (detail is Map) {
          final message = (detail['message'] ?? '').toString().trim();
          final hint = (detail['hint'] ?? '').toString().trim();
          final code = (detail['code'] ?? '').toString().trim();
          if (message.isNotEmpty) {
            final buffer = StringBuffer(message);
            if (code.isNotEmpty) buffer.write('\n[$code]');
            if (hint.isNotEmpty) buffer.write('\n$hint');
            return buffer.toString();
          }
        }
        // Auth/validation errors keep FastAPI's plain-string detail.
        if (detail is String && detail.trim().isNotEmpty) return detail.trim();
        // FastAPI validation errors (422) are a list of
        // {loc: [...], msg: ...}. Include the FIELD NAME — a bare
        // "Field required; Field required" says nothing about which fields,
        // which is exactly what made this bug hard to place.
        if (detail is List) {
          final lines = <String>[];
          for (final d in detail.whereType<Map>()) {
            final msg = (d['msg'] ?? '').toString();
            if (msg.isEmpty) continue;
            final loc = (d['loc'] as List?)
                    ?.where((p) => p != 'body')
                    .map((p) => p.toString())
                    .join('.') ??
                '';
            lines.add(loc.isEmpty ? msg : '$loc: $msg');
          }
          if (lines.isNotEmpty) return lines.join('\n');
        }
      }
      if (e.isNetworkError) {
        return 'Could not reach the ZITLAS server. Check your connection '
            'and try again.';
      }
      return '${e.message} (HTTP ${e.statusCode})';
    }
    return 'We could not send your message. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: ZitlasTokens.bgPrimary,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: ZitlasTokens.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('New Conversation',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: ZitlasTokens.textPrimary)),
              const SizedBox(height: 4),
              const Text('Team ZITLAS will reply right here in the app.',
                  style: TextStyle(
                      fontSize: 13, color: ZitlasTokens.textSecondary)),
              const SizedBox(height: 18),
              _field('Subject', _subjectErr,
                  TextField(
                    controller: _subject,
                    maxLength: 200,
                    style: _fieldStyle,
                    cursorColor: _fieldText,
                    decoration: _dec('What do you need help with?'),
                  )),
              _field('Category', _categoryErr,
                  DropdownButtonFormField<String>(
                    initialValue: _category,
                    isExpanded: true,
                    // `style` colours the SELECTED value and the menu items;
                    // `dropdownColor` is the menu surface behind them. Without
                    // both, the value was white-on-white and the menu would
                    // have been dark-on-black (canvasColor is #000000).
                    style: _fieldStyle,
                    dropdownColor: _fieldFill,
                    // The unselected placeholder must be supplied as a `hint`
                    // WIDGET, not as decoration.hintText: DropdownButton draws
                    // its own placeholder with ThemeData.hintColor, which is
                    // Colors.white60 under Brightness.dark (theme_data.dart:487)
                    // and so vanished on the white field.
                    hint: const Text('Select a category',
                        style: TextStyle(color: _fieldHint, fontSize: 14)),
                    decoration: _dec(''),
                    items: _categories
                        .map((c) => DropdownMenuItem(
                              value: c,
                              child: Text(c, style: _fieldStyle),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _category = v),
                  )),
              _field('Message', _messageErr,
                  TextField(
                    controller: _message,
                    minLines: 4,
                    maxLines: 8,
                    maxLength: 5000,
                    textCapitalization: TextCapitalization.sentences,
                    style: _fieldStyle,
                    cursorColor: _fieldText,
                    decoration: _dec('Describe your issue…'),
                  )),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: ZitlasTokens.primary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _sending ? null : _submit,
                  child: _sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Send Message',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Help Center field colours (LOCAL, not the global theme) ──────────────
  //
  // The app's ThemeData is Brightness.dark, so any field that does not state
  // its own colour inherits WHITE text — and these fields sit on the white
  // ZitlasTokens.bgCard surface, which is why typing was invisible.
  //
  // Two DIFFERENT Material slots are involved, which is what made the first
  // attempt miss the dropdown:
  //   * TextField typed text  -> textTheme.bodyLarge   (text_field.dart:1893)
  //   * DropdownButton value  -> textTheme.titleMedium (dropdown.dart:1449)
  //   * Dropdown menu surface -> canvasColor           (dropdown.dart:341)
  // Rather than redefine those three globally (which would reach every screen
  // in the app days before launch), each widget below states its own colour.
  // Scope is exactly this screen.
  static const _fieldText = ZitlasTokens.textPrimary; // #17221A near-black
  static const _fieldHint = ZitlasTokens.textMuted;   // readable on white
  static const _fieldFill = ZitlasTokens.bgCard;      // #FFFFFF
  static const _fieldStyle = TextStyle(color: _fieldText, fontSize: 14);

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        // Stated explicitly: the theme's hintStyle is tuned for a dark field.
        hintStyle: const TextStyle(color: _fieldHint, fontSize: 14),
        counterText: '',
        filled: true,
        fillColor: _fieldFill,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
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
      );

  Widget _field(String label, String? error, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: ZitlasTokens.textSecondary)),
          const SizedBox(height: 6),
          child,
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(error,
                  style: const TextStyle(
                      fontSize: 12, color: ZitlasTokens.danger)),
            ),
        ],
      ),
    );
  }
}
