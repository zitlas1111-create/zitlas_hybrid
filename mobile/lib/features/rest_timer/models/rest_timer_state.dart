/// Lifecycle of the (single, app-wide) Rest Timer.
enum RestTimerStatus {
  /// No timer running. Duration is selectable.
  idle,

  /// Counting down. Source of truth is [RestTimerSnapshot.endEpochMs], not a
  /// decrementing counter — see the controller for why.
  running,

  /// Frozen at [RestTimerSnapshot.pausedRemainingSeconds]. No end timestamp
  /// while paused: there is nothing counting down TO.
  paused,

  /// Reached zero; the alarm (looping audio + repeating vibration) is
  /// actively ringing and has NOT yet been acknowledged. Distinct from
  /// [completed] on purpose — the athlete must explicitly press "Stop
  /// Alarm" to move past this state; it does not clear itself.
  alarming,

  /// The alarm has been stopped (or, on a cold app relaunch, was found to
  /// have expired while the process was dead — see the controller's
  /// `init()`). Distinct from [idle] so the Training card and the watch
  /// screen can both show "Rest Complete" / "Start again" instead of
  /// silently resetting to the last-selected duration.
  completed,
}

/// The entire persisted/observable state of the Rest Timer.
///
/// End-time based, per spec: while [status] is [RestTimerStatus.running],
/// remaining time is ALWAYS derived as `endEpochMs - now`, never by
/// decrementing an integer once a second. That is what makes the timer
/// immune to drift and to the app being backgrounded, killed, or the device
/// being locked — recomputing from two timestamps gives the exact right
/// answer regardless of how long this object sat unobserved.
class RestTimerSnapshot {
  const RestTimerSnapshot({
    required this.durationSeconds,
    required this.status,
    this.endEpochMs,
    this.pausedRemainingSeconds,
  });

  /// The selected duration in seconds (60–1200 i.e. 1–20 minutes). This is
  /// what a Reset returns to, and what a fresh [idle] state displays.
  final int durationSeconds;

  final RestTimerStatus status;

  /// Set only while [status] is [RestTimerStatus.running] — the wall-clock
  /// moment (`DateTime.now().millisecondsSinceEpoch`) the countdown reaches
  /// zero. Null in every other status.
  final int? endEpochMs;

  /// Set only while [status] is [RestTimerStatus.paused] — the EXACT second
  /// count at the moment Pause was pressed, frozen. Null in every other
  /// status. Deliberately not "recomputed from a stored pause timestamp": a
  /// paused timer must show the SAME number no matter how long it stays
  /// paused, and storing the frozen value directly is what guarantees that
  /// rather than relying on a second timestamp diff staying at zero.
  final int? pausedRemainingSeconds;

  static const _idleSentinel = -1;

  factory RestTimerSnapshot.idle(int durationSeconds) => RestTimerSnapshot(
        durationSeconds: durationSeconds,
        status: RestTimerStatus.idle,
      );

  RestTimerSnapshot copyWith({
    int? durationSeconds,
    RestTimerStatus? status,
    Object? endEpochMs = _idleSentinel,
    Object? pausedRemainingSeconds = _idleSentinel,
  }) {
    return RestTimerSnapshot(
      durationSeconds: durationSeconds ?? this.durationSeconds,
      status: status ?? this.status,
      endEpochMs: endEpochMs == _idleSentinel ? this.endEpochMs : endEpochMs as int?,
      pausedRemainingSeconds:
          pausedRemainingSeconds == _idleSentinel ? this.pausedRemainingSeconds : pausedRemainingSeconds as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'durationSeconds': durationSeconds,
        'status': status.name,
        'endEpochMs': endEpochMs,
        'pausedRemainingSeconds': pausedRemainingSeconds,
      };

  static RestTimerSnapshot fromJson(Map<String, dynamic> json) {
    final statusName = json['status'] as String?;
    final status = RestTimerStatus.values.firstWhere(
      (s) => s.name == statusName,
      orElse: () => RestTimerStatus.idle,
    );
    return RestTimerSnapshot(
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 300,
      status: status,
      endEpochMs: (json['endEpochMs'] as num?)?.toInt(),
      pausedRemainingSeconds: (json['pausedRemainingSeconds'] as num?)?.toInt(),
    );
  }
}
