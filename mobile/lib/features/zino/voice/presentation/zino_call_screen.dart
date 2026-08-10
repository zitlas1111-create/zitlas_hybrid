import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/steps/step_tracking_service.dart';
import '../../../../core/voice/voice_language.dart';
import '../../../../core/voice/voice_language_store.dart';
import '../../../../core/voice/voice_recorder.dart';
import '../../../../core/voice/voice_service.dart';
import '../../data/zino_context_builder.dart';
import '../zino_call_controller.dart';
import 'voice_language_sheet.dart';

/// Full-screen "Talk with Zino".
///
/// Deliberately its own visual language — a dark, focused call surface rather
/// than the app's light content theme. During a voice call there is nothing to
/// read and nothing to scan; the screen's whole job is to make the current
/// state (listening / thinking / speaking) unmistakable at a glance and to put
/// End Call within thumb reach.
class ZinoCallScreen extends StatefulWidget {
  const ZinoCallScreen({super.key});

  @override
  State<ZinoCallScreen> createState() => _ZinoCallScreenState();
}

class _ZinoCallScreenState extends State<ZinoCallScreen> {
  ZinoCallController? _controller;
  String? _error;
  bool _starting = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  /// Resolves the language BEFORE the call opens — asking mid-conversation
  /// which language to speak would be absurd, and the first spoken word has to
  /// already be in the right one.
  Future<void> _bootstrap() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _error = 'Sign in to talk with Zino.';
        _starting = false;
      });
      return;
    }

    final store = VoiceLanguageStore(firestore: FirebaseFirestore.instance);
    final stored = await store.load(user.uid);
    if (!mounted) return;

    var language = stored.language;
    if (language == null) {
      // `known == false` means the lookup FAILED rather than "never chose".
      // Prompting then risks overwriting a real remote preference, so fall
      // back to the recommended default and ask again on a healthy load.
      if (!stored.known) {
        language = VoiceLanguage.fallback;
      } else {
        language = await showVoiceLanguageSheet(context, dismissible: false);
        if (!mounted) return;
        language ??= VoiceLanguage.fallback;
        await store.save(user.uid, language);
      }
    }

    if (!mounted) return;
    final controller = ZinoCallController(
      uid: user.uid,
      athleteName: user.displayName ?? 'Athlete',
      language: language,
      voice: VoiceService(),
      recorder: VoiceRecorder(),
      contextBuilder: ZinoContextBuilder(
        firestore: FirebaseFirestore.instance,
        stepService: StepTrackingService(),
      ),
    );
    setState(() {
      _controller = controller;
      _starting = false;
    });
    await controller.start();
  }

  @override
  void dispose() {
    _controller?.endCall();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _CallScaffold(child: Center(child: _Message(text: _error!)));
    }
    final controller = _controller;
    if (_starting || controller == null) {
      return const _CallScaffold(
        child: Center(child: CircularProgressIndicator(color: Color(0xFF234B35))),
      );
    }
    return ChangeNotifierProvider.value(
      value: controller,
      child: const _CallBody(),
    );
  }
}

/// Shared dark surface so the loading/error states match the call itself.
class _CallScaffold extends StatelessWidget {
  const _CallScaffold({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B10),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF15151F), Color(0xFF0B0B10)],
          ),
        ),
        child: SafeArea(child: child),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
        ),
      );
}

class _CallBody extends StatelessWidget {
  const _CallBody();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ZinoCallController>();

    return _CallScaffold(
      child: Column(
        children: [
          const SizedBox(height: 8),
          _Header(controller: c),
          const Spacer(),
          _Avatar(state: c.state),
          const SizedBox(height: 28),
          _StatusBlock(controller: c),
          const SizedBox(height: 20),
          _Waveform(state: c.state),
          const Spacer(),
          if (c.transcript.isNotEmpty) _LastLine(controller: c),
          const SizedBox(height: 18),
          _Controls(controller: c),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});
  final ZinoCallController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const Spacer(),
          Column(
            children: [
              Text(
                controller.durationLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              // Honest about which voice is actually speaking — the premium
              // ElevenLabs voice or the device fallback.
              Text(
                controller.usingZinoVoice ? "Zino's voice" : 'Device voice',
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Language',
            icon: const Icon(Icons.translate_rounded, color: Colors.white70, size: 20),
            onPressed: () async {
              final picked = await showVoiceLanguageSheet(
                context,
                current: controller.language,
              );
              if (picked == null) return;
              final uid = FirebaseAuth.instance.currentUser?.uid;
              if (uid != null) {
                await VoiceLanguageStore(firestore: FirebaseFirestore.instance)
                    .save(uid, picked);
              }
              await controller.setLanguage(picked);
            },
          ),
        ],
      ),
    );
  }
}

/// The Zino avatar, with a halo whose behaviour encodes the call state:
/// a slow breath while idle, an eager pulse while listening, a tight spin
/// while thinking, and a wide bloom while speaking.
class _Avatar extends StatefulWidget {
  const _Avatar({required this.state});
  final ZinoCallState state;

  @override
  State<_Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<_Avatar> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 168.0;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        final (double amplitude, Color glow) = switch (widget.state) {
          ZinoCallState.listening => (0.22, const Color(0xFF3A8F8B)), // teal for engagement
          ZinoCallState.thinking => (0.10, const Color(0xFF6B5878)), // plum for AI
          ZinoCallState.speaking => (0.30, const Color(0xFF234B35)),
          ZinoCallState.error => (0.05, const Color(0xFFE5484D)),
          _ => (0.08, const Color(0xFF234B35)),
        };
        final wave = math.sin(t * 2 * math.pi);

        return SizedBox(
          width: size + 90,
          height: size + 90,
          child: Stack(
            alignment: Alignment.center,
            children: [
              for (var ring = 0; ring < 3; ring++)
                _Halo(
                  // Rings are offset thirds apart so they bloom in sequence
                  // rather than throbbing as one solid blob.
                  progress: (t + ring / 3) % 1.0,
                  color: glow,
                  baseSize: size,
                  amplitude: amplitude,
                ),
              Transform.scale(
                scale: 1 + amplitude * 0.10 * wave,
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: glow.withValues(alpha: 0.65), width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: glow.withValues(alpha: 0.35),
                        blurRadius: 46,
                        spreadRadius: 6,
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/images/zino.png',
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: const Color(0xFF1D1D28),
                        alignment: Alignment.center,
                        child: const Icon(Icons.auto_awesome, color: Colors.white70, size: 52),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Halo extends StatelessWidget {
  const _Halo({
    required this.progress,
    required this.color,
    required this.baseSize,
    required this.amplitude,
  });

  final double progress;
  final Color color;
  final double baseSize;
  final double amplitude;

  @override
  Widget build(BuildContext context) {
    final scale = 1 + progress * amplitude * 2.4;
    final opacity = (1 - progress).clamp(0.0, 1.0) * 0.45;
    return IgnorePointer(
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: baseSize,
          height: baseSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color.withValues(alpha: opacity), width: 2),
          ),
        ),
      ),
    );
  }
}

class _StatusBlock extends StatelessWidget {
  const _StatusBlock({required this.controller});
  final ZinoCallController controller;

  @override
  Widget build(BuildContext context) {
    final isError = controller.state == ZinoCallState.error;
    return Column(
      children: [
        const Text(
          'Zino',
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 6),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: Text(
            isError ? (controller.errorMessage ?? 'Something went wrong') : controller.statusLabel,
            key: ValueKey(isError ? controller.errorMessage : controller.statusLabel),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isError ? const Color(0xFFFF8A8D) : Colors.white60,
              fontSize: 13.5,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}

/// Sound-wave bars. Animated only while there's genuinely audio moving —
/// a waveform that dances during silence is a lie about what the mic is doing.
class _Waveform extends StatefulWidget {
  const _Waveform({required this.state});
  final ZinoCallState state;

  @override
  State<_Waveform> createState() => _WaveformState();
}

class _WaveformState extends State<_Waveform> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  static const _bars = 5;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.state == ZinoCallState.listening ||
        widget.state == ZinoCallState.speaking;
    final color = widget.state == ZinoCallState.listening
        ? const Color(0xFF3A8F8B)
        : const Color(0xFF234B35);

    return SizedBox(
      height: 34,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(_bars, (i) {
              final phase = (_c.value + i / _bars) % 1.0;
              final h = active
                  ? 8 + 24 * (0.5 + 0.5 * math.sin(phase * 2 * math.pi)).abs()
                  : 6.0;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                margin: const EdgeInsets.symmetric(horizontal: 3.5),
                width: 4,
                height: h,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: active ? 0.9 : 0.25),
                  borderRadius: BorderRadius.circular(4),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

/// The most recent line, so the athlete can confirm they were heard correctly
/// — the single most reassuring thing to show during voice input.
class _LastLine extends StatelessWidget {
  const _LastLine({required this.controller});
  final ZinoCallController controller;

  @override
  Widget build(BuildContext context) {
    final turn = controller.transcript.last;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              turn.isUser ? 'You' : 'Zino',
              style: TextStyle(
                color: turn.isUser ? Colors.white38 : const Color(0xFFFFB74D),
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              turn.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.controller});
  final ZinoCallController controller;

  @override
  Widget build(BuildContext context) {
    final listening = controller.state == ZinoCallState.listening;
    final canTalk = !controller.isBusy;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _RoundButton(
              icon: controller.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
              label: controller.muted ? 'Unmute' : 'Mute',
              onTap: controller.toggleMute,
              active: controller.muted,
            ),
            const SizedBox(width: 22),

            // Press-and-hold to talk. Holding is unambiguous about when the
            // mic is open — a toggle leaves people guessing whether they're
            // still being recorded.
            GestureDetector(
              onTapDown: canTalk ? (_) => controller.startListening() : null,
              onTapUp: listening ? (_) => controller.stopAndSend() : null,
              onTapCancel: listening ? controller.stopAndSend : null,
              onTap: controller.state == ZinoCallState.error ? controller.retry : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: listening ? 88 : 78,
                height: listening ? 88 : 78,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: listening
                        ? const [Color(0xFF3A8F8B), Color(0xFF2C6F6C)]
                        : const [Color(0xFF234B35), Color(0xFF2E5F47)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (listening ? const Color(0xFF3A8F8B) : const Color(0xFF234B35))
                          .withValues(alpha: 0.45),
                      blurRadius: 26,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Icon(
                  controller.state == ZinoCallState.error
                      ? Icons.refresh_rounded
                      : (listening ? Icons.graphic_eq_rounded : Icons.mic_rounded),
                  color: Colors.white,
                  size: listening ? 36 : 32,
                ),
              ),
            ),
            const SizedBox(width: 22),
            _RoundButton(
              icon: controller.speakerOn
                  ? Icons.volume_up_rounded
                  : Icons.volume_down_rounded,
              label: 'Speaker',
              onTap: controller.toggleSpeaker,
              active: !controller.speakerOn,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          listening ? 'Release to send' : 'Hold to talk',
          style: const TextStyle(color: Colors.white38, fontSize: 11.5),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (controller.transcript.any((t) => !t.isUser))
              TextButton.icon(
                onPressed: controller.isBusy ? null : controller.replayLast,
                icon: const Icon(Icons.replay_rounded, size: 16, color: Colors.white54),
                label: const Text('Replay', style: TextStyle(color: Colors.white54, fontSize: 12.5)),
              ),
            const SizedBox(width: 8),
            _EndCallButton(
              onTap: () async {
                await controller.endCall();
                if (context.mounted) Navigator.of(context).maybePop();
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? Colors.white.withValues(alpha: 0.92)
                : Colors.white.withValues(alpha: 0.10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Icon(
            icon,
            color: active ? const Color(0xFF15151F) : Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }
}

class _EndCallButton extends StatelessWidget {
  const _EndCallButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'End call',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
          decoration: BoxDecoration(
            color: const Color(0xFFE5484D),
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFE5484D).withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.call_end_rounded, color: Colors.white, size: 19),
              SizedBox(width: 8),
              Text(
                'End Call',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
