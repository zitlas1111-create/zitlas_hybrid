import 'package:flutter/material.dart';

import '../theme/zitlas_tokens.dart';
import 'presence_repository.dart';
import 'presence_status.dart';

/// The green dot — the ONLY way presence should ever be rendered.
///
/// Subscribes to derived presence for [uid] and starts from
/// [PresenceStatus.unknown], i.e. grey. The bug this exists to prevent is
/// the previous UI's `p?.isOnline ?? true`, which painted a user green
/// when there was no presence data at all.
class PresenceDot extends StatelessWidget {
  const PresenceDot({
    super.key,
    required this.uid,
    this.size = 12,
    this.borderColor,
    this.repository,
  });

  final String uid;
  final double size;

  /// Set when the dot overlaps an avatar and needs to punch out of it.
  final Color? borderColor;

  @visibleForTesting
  final PresenceRepository? repository;

  @override
  Widget build(BuildContext context) {
    return PresenceBuilder(
      uid: uid,
      repository: repository,
      builder: (context, status) {
        final border = borderColor;
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: status.isOnline ? ZitlasTokens.success : ZitlasTokens.textMuted,
            shape: BoxShape.circle,
            border: border == null
                ? null
                : Border.all(color: border, width: size * 0.18),
          ),
        );
      },
    );
  }
}

/// Presence for [uid], for callers that need the label or their own layout
/// rather than a bare dot.
class PresenceBuilder extends StatefulWidget {
  const PresenceBuilder({
    super.key,
    required this.uid,
    required this.builder,
    this.repository,
  });

  final String uid;
  final Widget Function(BuildContext context, PresenceStatus status) builder;

  @visibleForTesting
  final PresenceRepository? repository;

  @override
  State<PresenceBuilder> createState() => _PresenceBuilderState();
}

class _PresenceBuilderState extends State<PresenceBuilder> {
  late Stream<PresenceStatus> _stream;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  // Without this a rebuild with a different uid would keep showing the
  // previous person's presence — the sort of mix-up that is worse than no
  // dot at all.
  @override
  void didUpdateWidget(PresenceBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) _subscribe();
  }

  void _subscribe() {
    _stream = (widget.repository ?? PresenceRepository()).watch(widget.uid);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PresenceStatus>(
      // Keyed on uid so a uid change builds FRESH state seeded with
      // `unknown`. StreamBuilder otherwise carries its last snapshot across
      // a stream swap, which would show person B person A's green dot until
      // B's first heartbeat arrived.
      key: ValueKey(widget.uid),
      stream: _stream,
      initialData: PresenceStatus.unknown,
      builder: (context, snapshot) => widget.builder(
        context,
        snapshot.data ?? PresenceStatus.unknown,
      ),
    );
  }
}
