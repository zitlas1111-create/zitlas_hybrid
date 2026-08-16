import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/steps/step_tracking_service.dart';
import '../../../../core/theme/zitlas_tokens.dart';
import '../../data/zino_context_builder.dart';
import '../../data/zino_repository.dart';
import '../../models/zino_action.dart';
import '../../models/zino_message.dart';
import '../../zino_controller.dart';

/// Native rebuild of the website's Zino chat overlay
/// (`zino.js`'s `FloatingAssistant` + `zino.css`'s `.zn-chat-*`).
///
/// Same identity, same quick actions, same conversational behaviour — adapted
/// from a floating desktop card to a full mobile screen, which is the right
/// mobile shape for a keyboard-driven chat.
class ZinoScreen extends StatelessWidget {
  const ZinoScreen({super.key, this.screenContext = ZinoScreenContext.other, this.viewingExpertId});

  /// Where the athlete came from, so Zino can anchor ambiguous questions —
  /// the mobile equivalent of the website's `current_page`.
  final ZinoScreenContext screenContext;
  final String? viewingExpertId;

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        backgroundColor: ZitlasTokens.bgStart,
        body: Center(
          child: Text(
            'Sign in to chat with Zino',
            style: TextStyle(color: ZitlasTokens.textSecondary),
          ),
        ),
      );
    }

    return ChangeNotifierProvider(
      // Keyed by uid so a different signed-in athlete gets a brand-new
      // controller (and therefore a different history bucket) rather than
      // inheriting the previous one's thread.
      key: ValueKey(user.uid),
      create: (_) => ZinoController(
        uid: user.uid,
        athleteName: user.displayName ?? 'Athlete',
        repository: ZinoRepository(),
        contextBuilder: ZinoContextBuilder(
          firestore: FirebaseFirestore.instance,
          stepService: StepTrackingService(),
        ),
      )
        ..screen = screenContext
        ..viewingExpertId = viewingExpertId,
      child: const _ZinoBody(),
    );
  }
}

class _ZinoBody extends StatefulWidget {
  const _ZinoBody();

  @override
  State<_ZinoBody> createState() => _ZinoBodyState();
}

class _ZinoBodyState extends State<_ZinoBody> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    // Posted to the next frame so the new bubble is laid out before we
    // measure — otherwise maxScrollExtent is one message stale.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send(String text) async {
    final controller = context.read<ZinoController>();
    _input.clear();
    _scrollToEnd();
    await controller.send(text);
    _scrollToEnd();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ZinoController>();

    return Scaffold(
      backgroundColor: ZitlasTokens.bgStart,
      appBar: AppBar(
        backgroundColor: ZitlasTokens.bgCard,
        elevation: 0,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: ZitlasTokens.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Row(
          children: [
            const _ZinoAvatar(size: 34),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Zino',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                    color: ZitlasTokens.textPrimary,
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: ZitlasTokens.success,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      controller.sending ? 'Thinking…' : 'Online · AI Fitness Companion',
                      style: const TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (!controller.isEmpty)
            IconButton(
              tooltip: 'Clear chat',
              icon: const Icon(Icons.delete_outline_rounded, color: ZitlasTokens.textMuted, size: 20),
              onPressed: () => _confirmClear(context, controller),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: controller.isEmpty
                  ? _Greeting(text: controller.greeting)
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
                      itemCount: controller.messages.length + (controller.sending ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i >= controller.messages.length) return const _TypingBubble();
                        return _Bubble(message: controller.messages[i]);
                      },
                    ),
            ),
            if (controller.errorMessage != null)
              _ErrorBar(
                message: controller.errorMessage!,
                onRetry: controller.sending ? null : controller.retry,
              ),
            if (controller.pendingAction != null)
              _ActionChip(action: controller.pendingAction!),
            _ChipsRow(onTap: controller.sending ? null : _send),
            _InputBar(
              controller: _input,
              enabled: !controller.sending,
              onSend: _send,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, ZinoController controller) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ZitlasTokens.bgCard,
        title: const Text('Clear chat?', style: TextStyle(color: ZitlasTokens.textPrimary)),
        content: const Text(
          "This clears your conversation with Zino. Your plans and progress aren't affected.",
          style: TextStyle(color: ZitlasTokens.textSecondary),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear', style: TextStyle(color: ZitlasTokens.danger)),
          ),
        ],
      ),
    );
    if (ok == true) await controller.clear();
  }
}

/// `.zn-chat-avatar` — the real Zino asset, not a generic robot glyph.
class _ZinoAvatar extends StatelessWidget {
  const _ZinoAvatar({this.size = 30});
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: Image.asset(
        'assets/images/zino.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        // A missing asset must never blank the chat header.
        errorBuilder: (_, _, _) => Container(
          width: size,
          height: size,
          color: ZitlasTokens.primary,
          alignment: Alignment.center,
          child: Text('Z', style: TextStyle(fontSize: size * 0.5, color: Colors.white)),
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _ZinoAvatar(size: 72),
            const SizedBox(height: 18),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14.5,
                height: 1.55,
                color: ZitlasTokens.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `.zn-bubble--user` / `.zn-bubble--zino`.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final ZinoMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: isUser ? ZitlasTokens.primary : ZitlasTokens.bgCard,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
          border: isUser ? null : Border.all(color: ZitlasTokens.borderSub),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              message.text,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: isUser ? Colors.white : ZitlasTokens.textPrimary,
              ),
            ),
            if (message.failed) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 12, color: Colors.white.withValues(alpha: 0.85)),
                  const SizedBox(width: 4),
                  Text(
                    'Not delivered',
                    style: TextStyle(fontSize: 10.5, color: Colors.white.withValues(alpha: 0.85)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// `.zn-typing` — the three-dot pulse while Zino composes a reply.
class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: ZitlasTokens.bgCard,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(16),
          ),
          border: Border.all(color: ZitlasTokens.borderSub),
        ),
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              // Staggered thirds so the dots ripple rather than blink together.
              final t = ((_c.value + i * 0.22) % 1.0);
              final opacity = 0.3 + 0.7 * (t < 0.5 ? t * 2 : (1 - t) * 2);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2.5),
                child: Opacity(
                  opacity: opacity.clamp(0.3, 1.0),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: ZitlasTokens.textMuted,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

/// The one navigation shortcut offered for the latest exchange. Tapping it IS
/// the confirmation — nothing navigates on its own.
class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.action});
  final ZinoAction action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: ZitlasTokens.primary.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => context.push(action.route),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: ZitlasTokens.primary.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(action.icon, style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 7),
                  Text(
                    action.label,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: ZitlasTokens.primary,
                    ),
                  ),
                  const SizedBox(width: 3),
                  const Icon(Icons.arrow_forward_rounded, size: 13, color: ZitlasTokens.primary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.zn-chips-row` — the nine quick actions, ported verbatim.
class _ChipsRow extends StatelessWidget {
  const _ChipsRow({required this.onTap});
  final void Function(String question)? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: kZinoChips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final chip = kZinoChips[i];
          return Material(
            color: ZitlasTokens.bgCard,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: onTap == null ? null : () => onTap!(chip.question),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: ZitlasTokens.borderSub),
                ),
                child: Text(
                  '${chip.icon} ${chip.label}',
                  style: const TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message, required this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: ZitlasTokens.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZitlasTokens.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: ZitlasTokens.primary,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Retry', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
        ],
      ),
    );
  }
}

/// `.zn-chat-input-bar`.
class _InputBar extends StatelessWidget {
  const _InputBar({required this.controller, required this.enabled, required this.onSend});

  final TextEditingController controller;
  final bool enabled;
  final void Function(String text) onSend;

  @override
  Widget build(BuildContext context) {
    void submit() {
      final text = controller.text.trim();
      if (text.isEmpty || !enabled) return;
      onSend(text);
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: ZitlasTokens.borderSub)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => submit(),
              style: const TextStyle(fontSize: 14, color: ZitlasTokens.textPrimary),
              decoration: InputDecoration(
                hintText: 'Ask Zino anything…',
                hintStyle: const TextStyle(fontSize: 14, color: ZitlasTokens.textMuted),
                filled: true,
                fillColor: ZitlasTokens.bgCard,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: const BorderSide(color: ZitlasTokens.borderSub),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: const BorderSide(color: ZitlasTokens.borderSub),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: const BorderSide(color: ZitlasTokens.primary),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: enabled ? ZitlasTokens.primary : ZitlasTokens.borderSub,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled ? submit : null,
              child: const Padding(
                padding: EdgeInsets.all(11),
                child: Icon(Icons.send_rounded, size: 19, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
