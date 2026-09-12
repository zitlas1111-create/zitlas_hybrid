import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../fcm_service.dart';

/// "Notifications are off", with the way to turn them back on.
///
/// Shown on the expert dashboard: an expert who cannot be notified misses new
/// coaching and review requests without ever finding out why, and nothing
/// else on that screen would tell them. Renders nothing unless notifications
/// are genuinely off on this device.
///
/// Dismissible for the session only — the problem has not gone away, so it
/// returns on the next launch.
class PushPermissionBanner extends StatefulWidget {
  const PushPermissionBanner({super.key, required this.onEnable, this.state});

  /// "Turn on" / "Open settings" — see `FcmService.enableFromSettings`.
  final Future<void> Function() onEnable;

  /// Defaults to [FcmService.permissionState]; injectable for tests.
  final ValueListenable<PushPermissionState>? state;

  @override
  State<PushPermissionBanner> createState() => _PushPermissionBannerState();
}

class _PushPermissionBannerState extends State<PushPermissionBanner> {
  bool _dismissed = false;
  bool _busy = false;

  Future<void> _enable() async {
    setState(() => _busy = true);
    try {
      await widget.onEnable();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PushPermissionState>(
      valueListenable: widget.state ?? FcmService.permissionState,
      builder: (context, value, _) {
        final off = value == PushPermissionState.askable ||
            value == PushPermissionState.blocked;
        if (!off || _dismissed) return const SizedBox.shrink();
        final blocked = value == PushPermissionState.blocked;
        return Material(
          color: const Color(0xFFFFF4E5),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
            child: Row(
              children: [
                const Icon(
                  Icons.notifications_off_outlined,
                  size: 20,
                  color: Color(0xFFB45309),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Notifications are off — you will not be alerted to new '
                    'client requests, reviews or messages.',
                    style: TextStyle(fontSize: 12.5, color: Color(0xFF7C2D12)),
                  ),
                ),
                TextButton(
                  key: const Key('pushBannerEnable'),
                  onPressed: _busy ? null : _enable,
                  child: Text(blocked ? 'Open settings' : 'Turn on'),
                ),
                IconButton(
                  key: const Key('pushBannerDismiss'),
                  tooltip: 'Dismiss',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _dismissed = true),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
