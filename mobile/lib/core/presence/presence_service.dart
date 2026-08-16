import 'dart:async';

import 'package:flutter/widgets.dart';

import '../storage/device_identity.dart';
import 'presence_repository.dart';
import 'presence_status.dart';

/// Publishes THIS device's presence, automatically.
///
/// The athlete/expert never touches a control: presence follows the app
/// lifecycle exactly the way Instagram's or Messenger's does. The manual
/// Online/Offline toggle this replaces was the entire reason stale users
/// stayed green — nothing but a human tap ever changed the old flag.
///
/// Deliberately FOREGROUND-ONLY. There is no background service, no
/// WorkManager job and no wake lock: a backgrounded app stops beating and
/// the TTL ([kPresenceTtl]) expires it. Keeping a phone "online" while the
/// app is closed would be both a battery cost and a lie.
///
/// One instance per process; sessions are keyed by [DeviceIdentity] so the
/// same physical device reuses its document across cold starts instead of
/// littering orphaned sessions.
class PresenceService with WidgetsBindingObserver {
  PresenceService._();

  static final PresenceService instance = PresenceService._();

  /// Swappable for tests only.
  @visibleForTesting
  static PresenceService createForTest({
    required PresenceRepository repository,
    required String deviceId,
  }) {
    final service = PresenceService._();
    service._repository = repository;
    service._deviceIdOverride = deviceId;
    return service;
  }

  PresenceRepository _repository = PresenceRepository();
  String? _deviceIdOverride;

  String? _uid;
  String? _deviceId;
  Timer? _heartbeat;
  bool _observing = false;

  /// The uid currently being published, or null when nobody is signed in.
  String? get currentUid => _uid;

  @visibleForTesting
  bool get isBeating => _heartbeat != null;

  /// Begins publishing presence for [uid]. Idempotent for the same uid, so
  /// it is safe to call from a `Consumer` that rebuilds freely.
  Future<void> start(String uid) async {
    if (uid.isEmpty || _uid == uid) return;
    // An account switch must retire the outgoing user's session on this
    // device before the incoming one starts, or the previous account is
    // left looking online from a phone they no longer hold.
    if (_uid != null) await stop();

    _uid = uid;
    final deviceId = _deviceIdOverride ?? await DeviceIdentity.get();

    // start() is async; a logout or account switch that raced ahead of the
    // device-id read must not resurrect the session. Assigning the field
    // only after the check keeps the two halves of the identity consistent.
    if (_uid != uid) return;
    _deviceId = deviceId;

    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    await _mark(online: true);
    _startHeartbeat();
  }

  /// Retires this device's session.
  ///
  /// Must run BEFORE `FirebaseAuth.signOut()` — the offline write needs a
  /// live auth context to satisfy the owner-only rule, exactly like the
  /// FCM device unregister it sits next to in [AuthState.signOut].
  Future<void> stop() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    final uid = _uid;
    final deviceId = _deviceId;
    _uid = null;
    _deviceId = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    if (uid != null && deviceId != null) {
      await _repository.beat(uid, deviceId, online: false);
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(kPresenceHeartbeat, (_) => _mark(online: true));
  }

  Future<void> _mark({required bool online}) async {
    final uid = _uid;
    final deviceId = _deviceId;
    if (uid == null || deviceId == null) return;
    await _repository.beat(uid, deviceId, online: online);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_uid == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_mark(online: true));
        _startHeartbeat();

      case AppLifecycleState.inactive:
        // Transient only — the notification shade, an incoming call banner,
        // the app switcher. Android also fires this immediately before a
        // real pause, so acting on it would flap the dot every time the
        // user glanced at a notification. `paused` is the real signal.
        break;

      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _heartbeat?.cancel();
        _heartbeat = null;
        // Best-effort. On `detached` the process is often gone before this
        // lands, which is precisely why correctness rests on the TTL and
        // not on this write.
        unawaited(_mark(online: false));
    }
  }
}
