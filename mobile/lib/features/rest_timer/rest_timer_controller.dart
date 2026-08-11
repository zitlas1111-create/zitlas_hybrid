import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

import '../../core/storage/local_storage_service.dart';
import 'data/rest_timer_notification_service.dart';
import 'models/rest_timer_state.dart';

/// The single, app-wide Rest Timer.
///
/// SINGLETON, not a per-screen controller: the Training Day card and the
/// dedicated Rest Timer screen must both observe the exact same running
/// countdown, and the countdown itself must keep being correct — via
/// end-timestamp math, not a live ticker — even while NEITHER of those
/// screens is mounted (the athlete backgrounds the app, or navigates to
/// Diet/Profile/anywhere else). A per-screen `ChangeNotifierProvider` would
/// dispose the object the moment its screen unmounts, which is exactly the
/// "leave the timer screen and it silently forgets" bug this must not have.
/// Mirrors the existing `LocalStorageService.instance` singleton shape
/// already used for the same "one object, initialized once in main(), read
/// everywhere" need.
///
/// TIMER ENGINE: while running, the source of truth is
/// [RestTimerSnapshot.endEpochMs] (`start time + duration`, a wall-clock
/// timestamp), and [remainingSeconds] is ALWAYS `endEpochMs - now`. The
/// 1-second [_ticker] exists ONLY to trigger a UI refresh — deleting it
/// would not change what time the timer thinks it is, only how often the
/// display updates. This is what makes the countdown immune to drift and to
/// however long the process was backgrounded: resuming just re-evaluates the
/// same subtraction against the current clock.
class RestTimerController extends ChangeNotifier with WidgetsBindingObserver {
  RestTimerController._({
    LocalStorageService? storage,
    AudioPlayer? player,
    RestTimerNotificationService? notifications,
    DateTime Function()? clock,
  })  : _storage = storage,
        _injectedPlayer = player,
        _notifications = notifications ?? RestTimerNotificationService(),
        _now = clock ?? DateTime.now;

  static RestTimerController? _instance;

  /// The one instance. Created lazily on first access rather than requiring
  /// every caller to thread a reference through — this is intentionally
  /// reachable the same way [LocalStorageService.instance] is.
  static RestTimerController get instance => _instance ??= RestTimerController._();

  final LocalStorageService? _storage;
  final RestTimerNotificationService _notifications;
  final DateTime Function() _now;

  /// Only set when a test explicitly injects one via [RestTimerController.debug].
  final AudioPlayer? _injectedPlayer;

  /// Created LAZILY, on first actual playback attempt — not eagerly in the
  /// constructor. `AudioPlayer()`'s own constructor talks to a platform
  /// channel immediately, so constructing one eagerly here would mean every
  /// `RestTimerController` (including the one real singleton, built at app
  /// startup) pays that platform-channel round trip — and any failure from
  /// it — before a single timer has ever run, and with no `try/catch` able to
  /// reach it (it would throw from inside THIS class's own constructor,
  /// before `_startAlarmAudio`'s try/catch exists to catch it). Deferring
  /// construction to the moment it is actually needed keeps the failure
  /// contained to exactly the operation the spec says may fail safely (§39).
  AudioPlayer? _player;

  /// The "isAlarmPlaying" guard (spec §11/§12): true from the moment the
  /// alarm loop + repeating vibration actually start, until [stopAlarm]
  /// turns them off. This is the ONE flag every alarm-start call site checks
  /// before touching the player, which is what makes "timer reaches zero
  /// once -> exactly one ringtone instance" true regardless of how many
  /// times a rebuild, a lifecycle resume, or a stray tick re-enters the
  /// alarm-start path.
  bool _alarmActive = false;

  /// Repeating pulse while the alarm rings — separate from the one-shot
  /// haptics a plain completion used to fire, and separate from [_ticker]
  /// (whose job ends the moment the countdown reaches zero; ringing is a
  /// distinct phase with its own lifecycle, not a continuation of counting
  /// down).
  Timer? _alarmVibrationTimer;

  /// Starts the looping alarm (audio + repeating vibration) exactly once per
  /// completion, guarded by [_alarmActive]. Idempotent — a second call while
  /// already alarming is a deliberate no-op, which is what stops a duplicate
  /// tick or a lifecycle-resume re-check from layering a second ringtone on
  /// top of the first.
  Future<void> _startAlarmEffects() async {
    if (_alarmActive) return;
    _alarmActive = true;
    unawaited(_startAlarmAudio());
    _startAlarmVibration();
  }

  /// The single place that turns the alarm off, whichever caller reaches it
  /// — [stopAlarm] (the STOP ALARM button) and the defensive call at the top
  /// of [reset] both funnel through here, so audio-stopping logic exists in
  /// exactly one place (spec §13).
  ///
  /// Deliberately synchronous, and deliberately does NOT await
  /// [_stopAlarmAudio] (mirroring [_startAlarmEffects]' `unawaited` start):
  /// dismissing an alarm must never be gated on the audio platform
  /// answering. The guard flag and the vibration timer are both torn down
  /// before this returns, so callers can flip state and rebuild the UI
  /// immediately; only the platform-side audio teardown continues in the
  /// background. Awaiting it here would mean a slow or unresponsive player
  /// leaves the athlete stuck watching a "STOP ALARM" button that has
  /// already been pressed.
  void _stopAlarmEffects() {
    if (!_alarmActive) return;
    _alarmActive = false;
    _stopAlarmVibration();
    unawaited(_stopAlarmAudio());
  }

  /// Loops the SAME ringtone asset the app already ships
  /// (`assets/sounds/rest_timer_complete.wav`, added for the original
  /// one-shot completion chime) — no new asset, no new package.
  /// `ReleaseMode.loop` is `audioplayers`' own native-loop mode: once set,
  /// the platform player restarts the clip on completion itself, so there is
  /// no Dart-side "wait for onPlayerComplete, then call play() again" gap
  /// between cycles.
  Future<void> _startAlarmAudio() async {
    try {
      final player = _injectedPlayer ?? (_player ??= AudioPlayer());
      await player.stop();
      await player.setReleaseMode(ReleaseMode.loop);
      await player.play(AssetSource('sounds/rest_timer_complete.wav'));
    } catch (e) {
      if (kDebugMode) debugPrint('[REST TIMER] alarm audio failed to start (non-fatal): $e');
    }
  }

  Future<void> _stopAlarmAudio() async {
    try {
      final player = _injectedPlayer ?? _player;
      if (player == null) return;
      await player.stop();
      // Restored to the non-looping default so a stray future playback on
      // this same player instance is never accidentally still in loop mode.
      await player.setReleaseMode(ReleaseMode.release);
    } catch (e) {
      if (kDebugMode) debugPrint('[REST TIMER] alarm audio failed to stop (non-fatal): $e');
    }
  }

  /// Fires one pulse immediately, then repeats every 1.6s while alarming —
  /// "repeat periodically", explicitly NOT a continuous buzz (spec §7/§36).
  /// `HapticFeedback`, same as the rest of this file — no new package, no
  /// new `VIBRATE` manifest permission.
  void _startAlarmVibration() {
    _alarmVibrationTimer?.cancel();
    _pulseOnce();
    _alarmVibrationTimer = Timer.periodic(const Duration(milliseconds: 1600), (_) => _pulseOnce());
  }

  void _pulseOnce() {
    try {
      HapticFeedback.heavyImpact();
    } catch (e) {
      if (kDebugMode) debugPrint('[REST TIMER] alarm haptics unavailable (non-fatal): $e');
    }
  }

  void _stopAlarmVibration() {
    _alarmVibrationTimer?.cancel();
    _alarmVibrationTimer = null;
  }

  static const _storageKey = 'zitlas_rest_timer';
  static const _defaultDurationSeconds = 300; // 5:00 — the card's own example default.
  static const minDurationSeconds = 60;
  static const maxDurationSeconds = 1200; // 20:00

  LocalStorageService? get _prefs {
    if (_storage != null) return _storage;
    try {
      return LocalStorageService.instance;
    } catch (_) {
      return null;
    }
  }

  RestTimerSnapshot _snapshot = RestTimerSnapshot.idle(_defaultDurationSeconds);
  RestTimerSnapshot get snapshot => _snapshot;

  Timer? _ticker;
  bool _initialized = false;
  bool _observing = false;

  /// Must be awaited once (from `main.dart`, after `LocalStorageService.init()`)
  /// before this is read anywhere — same convention as
  /// `LocalStorageService.init()`. Loads the persisted snapshot and
  /// reconciles it against the current clock.
  ///
  /// A persisted [RestTimerStatus.running] whose end time has already
  /// passed, OR a persisted [RestTimerStatus.alarming], both resolve
  /// straight to [RestTimerStatus.completed] here — SILENTLY, no audio, no
  /// vibration — because both mean the process was fully dead when zero was
  /// reached: there is no `AudioPlayer` instance left to loop, and the
  /// scheduled OS notification already delivered the real alert at the real
  /// time. Starting a fresh loop minutes or hours later, on cold relaunch,
  /// would be a surprise alarm with no relationship to when rest actually
  /// ended, which is worse than silence.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final json = _prefs?.getJson(_storageKey);
    if (json != null) {
      try {
        _snapshot = RestTimerSnapshot.fromJson(json);
      } catch (e) {
        if (kDebugMode) debugPrint('[REST TIMER] corrupt saved state, resetting: $e');
        _snapshot = RestTimerSnapshot.idle(_defaultDurationSeconds);
      }
    }

    if (_snapshot.status == RestTimerStatus.running) {
      final end = _snapshot.endEpochMs;
      if (end == null || _now().millisecondsSinceEpoch >= end) {
        // Expired while this object didn't exist to observe it — see the
        // silence rationale above.
        _snapshot = _snapshot.copyWith(status: RestTimerStatus.completed, endEpochMs: null);
        await _persist();
      } else {
        _startTicker();
        // The alarm survives process death on its own (that is the entire
        // point of `zonedSchedule` + Alarm Manager), so this is a repair, not
        // a requirement: re-asserting it is cheap and covers the edge case of
        // the OS having dropped it (e.g. an aggressive OEM battery manager).
        unawaited(_notifications.scheduleCompletion(DateTime.fromMillisecondsSinceEpoch(end)));
      }
    } else if (_snapshot.status == RestTimerStatus.alarming) {
      // The app was killed WHILE ringing. Audio cannot have survived that —
      // see the silence rationale above.
      _snapshot = _snapshot.copyWith(status: RestTimerStatus.completed, endEpochMs: null);
      await _persist();
    }

    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Recomputes immediately on return — the single most important line
      // for "leave the app, come back, see the right remaining time (or
      // start ringing if it expired while backgrounded)" rather than waiting
      // up to a second for the next tick. Deliberately the SAME call as the
      // live per-second tick, not a silent variant: unlike a cold relaunch
      // (handled in `init` above), the process was ALIVE the whole time it
      // was backgrounded, so a completion discovered here is exactly as real
      // as one discovered while the screen was open — it must ring, not
      // resolve quietly.
      _tick();
    }
  }

  // ── derived state ─────────────────────────────────────────────────────
  RestTimerStatus get status => _snapshot.status;
  int get durationSeconds => _snapshot.durationSeconds;

  /// Seconds left RIGHT NOW, for every status. Never decremented directly —
  /// always derived, per the class doc above.
  int get remainingSeconds {
    switch (_snapshot.status) {
      case RestTimerStatus.idle:
        return _snapshot.durationSeconds;
      case RestTimerStatus.completed:
        return 0;
      case RestTimerStatus.paused:
        return _snapshot.pausedRemainingSeconds ?? _snapshot.durationSeconds;
      case RestTimerStatus.alarming:
        return 0;
      case RestTimerStatus.running:
        final end = _snapshot.endEpochMs;
        if (end == null) return _snapshot.durationSeconds;
        final left = ((end - _now().millisecondsSinceEpoch) / 1000).ceil();
        return left.clamp(0, _snapshot.durationSeconds);
    }
  }

  /// 1.0 at full duration, 0.0 at zero. What the watch ring/percentage color
  /// bands are driven from (§8–9: percentage-based, not a fixed-duration
  /// assumption). Full at [RestTimerStatus.alarming] too — spec §16: "show
  /// the completion state" / "complete the circular ring animation" the
  /// moment zero is reached, not only once Stop Alarm is pressed.
  double get progress {
    if (_snapshot.durationSeconds <= 0) return 0;
    if (_snapshot.status == RestTimerStatus.completed || _snapshot.status == RestTimerStatus.alarming) {
      return 1;
    }
    return (remainingSeconds / _snapshot.durationSeconds).clamp(0.0, 1.0);
  }

  /// True only while the alarm is actively ringing — distinct from
  /// [status] `==` [RestTimerStatus.alarming] only in that this is the name
  /// the UI/tests reach for (spec's own vocabulary: "isAlarmPlaying").
  bool get isAlarming => _snapshot.status == RestTimerStatus.alarming;

  /// Whether a DIFFERENT duration can be picked right now — false while a
  /// timer is actually in flight (including while ringing), so the Training
  /// card and the timer screen both know to route back into the ACTIVE timer
  /// instead of offering a fresh duration picker (spec §30: never silently
  /// start a second timer).
  bool get hasActiveTimer =>
      _snapshot.status == RestTimerStatus.running ||
      _snapshot.status == RestTimerStatus.paused ||
      _snapshot.status == RestTimerStatus.alarming;

  // ── actions ───────────────────────────────────────────────────────────

  /// Only meaningful in [RestTimerStatus.idle] or [RestTimerStatus.completed]
  /// — changing the duration of an in-flight timer is not a supported
  /// action (there is no sensible "resize a running countdown" semantic), so
  /// this is a deliberate no-op otherwise rather than corrupting the running
  /// state.
  void setDuration(int seconds) {
    if (hasActiveTimer) return;
    final clamped = seconds.clamp(minDurationSeconds, maxDurationSeconds);
    _snapshot = RestTimerSnapshot.idle(clamped);
    unawaited(_persist());
    notifyListeners();
  }

  /// Starts counting down from [durationSeconds] (the currently selected
  /// value). A no-op while already running/paused — per spec §30, this is
  /// what the UI never even offers (Start is not shown in those states), but
  /// guarded here too since this is the one true instance and must not be
  /// corruptible into a second concurrent countdown by any caller.
  Future<void> start() async {
    if (hasActiveTimer) return;
    final end = _now().add(Duration(seconds: _snapshot.durationSeconds));
    _snapshot = _snapshot.copyWith(
      status: RestTimerStatus.running,
      endEpochMs: end.millisecondsSinceEpoch,
      pausedRemainingSeconds: null,
    );
    await _persist();
    _startTicker();
    unawaited(_notifications.scheduleCompletion(end));
    notifyListeners();
  }

  /// Freezes the countdown at its exact current second. Per spec §14: while
  /// paused, [remainingSeconds] must read the SAME number no matter how long
  /// the pause lasts — captured here as a plain integer specifically so
  /// there is no timestamp arithmetic left running that could reintroduce
  /// drift during the pause itself.
  Future<void> pause() async {
    if (_snapshot.status != RestTimerStatus.running) return;
    final frozen = remainingSeconds;
    _stopTicker();
    _snapshot = _snapshot.copyWith(
      status: RestTimerStatus.paused,
      endEpochMs: null,
      pausedRemainingSeconds: frozen,
    );
    await _persist();
    unawaited(_notifications.cancel());
    notifyListeners();
  }

  /// Continues from exactly [RestTimerSnapshot.pausedRemainingSeconds] — a
  /// NEW end timestamp computed from "now", never from re-adding elapsed
  /// pause time, which is what makes Resume resume rather than fast-forward.
  Future<void> resume() async {
    if (_snapshot.status != RestTimerStatus.paused) return;
    final remaining = _snapshot.pausedRemainingSeconds ?? _snapshot.durationSeconds;
    final end = _now().add(Duration(seconds: remaining));
    _snapshot = _snapshot.copyWith(
      status: RestTimerStatus.running,
      endEpochMs: end.millisecondsSinceEpoch,
      pausedRemainingSeconds: null,
    );
    await _persist();
    _startTicker();
    unawaited(_notifications.scheduleCompletion(end));
    notifyListeners();
  }

  /// Stops and returns to [RestTimerStatus.idle] at the SELECTED duration —
  /// never auto-starts (spec §15 is explicit about this). Defensively stops
  /// the alarm first: `reset` is reachable from every status in principle
  /// (defence in depth, not a UI path the spec offers while ringing — the
  /// ONLY control shown while alarming is Stop Alarm), and the alarm must
  /// NEVER survive a reset from any state (spec §3: "must never continue
  /// after Stop Alarm" — the same guarantee applies here).
  Future<void> reset() async {
    _stopAlarmEffects();
    _stopTicker();
    _snapshot = RestTimerSnapshot.idle(_snapshot.durationSeconds);
    await _persist();
    unawaited(_notifications.cancel());
    notifyListeners();
  }

  /// The STOP ALARM button's action — the ONE method that ends ringing.
  /// A no-op unless actually alarming, so a stray extra tap (e.g. a double
  /// tap before the UI has rebuilt) never does anything surprising.
  ///
  /// Silences and flips to [RestTimerStatus.completed] synchronously, and
  /// notifies BEFORE the `await` on persistence: the button must feel
  /// instant, and neither disk nor the audio platform may sit between the
  /// tap and the alarm stopping (see [_stopAlarmEffects]).
  Future<void> stopAlarm() async {
    if (_snapshot.status != RestTimerStatus.alarming) return;
    _stopAlarmEffects();
    _snapshot = _snapshot.copyWith(status: RestTimerStatus.completed);
    notifyListeners();
    await _persist();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  /// Test-only hook for exactly what a real per-second [Timer.periodic] tick
  /// does in production, without a test needing a real `Timer` or wall-clock
  /// wait — the deterministic [_now] injected via [RestTimerController.debug]
  /// already makes "time has passed" instant.
  ///
  /// `Future<void>` (unlike the production [_tick], which a real
  /// `Timer.periodic` callback must return `void` from) and awaits a couple
  /// of empty microtask turns before returning: [_enterAlarming] suspends at
  /// `await _persist()` before it reaches `_notifications.cancel()`, so a
  /// caller that asserts immediately after a synchronous [_tick] call would
  /// race that chain. This is a TEST-ONLY affordance for that — production
  /// code never needs to await a tick's side effects.
  @visibleForTesting
  Future<void> debugTick() async {
    _tick();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  /// Test-only window into the "isAlarmPlaying" guard (spec §11) — lets a
  /// test assert directly that exactly one alarm cycle is active, rather
  /// than inferring it indirectly from audio-player call counts.
  @visibleForTesting
  bool get debugAlarmActive => _alarmActive;

  /// Test-only: forces entry into ALARMING without waiting for real time to
  /// pass. [RestTimerController.instance] (unlike [RestTimerController.debug])
  /// has no injectable clock, so widget tests that exercise the real
  /// singleton cannot reach completion by advancing `flutter_test`'s
  /// `FakeAsync` — `FakeAsync.elapse()` only fakes `Timer`/microtask
  /// scheduling, never `DateTime.now()`, so [_now] keeps returning the real
  /// wall clock regardless of how much fake time a test elapses. The actual
  /// TIME-based trigger condition (`_now() >= end`) is exhaustively covered
  /// by `rest_timer_controller_test.dart`'s fake-clock tests; this seam
  /// exists only to let widget tests verify what the UI does once that
  /// condition is met, mirroring [_tick]'s own transition exactly (minus the
  /// clock check) rather than reimplementing it.
  @visibleForTesting
  Future<void> debugForceAlarming() async {
    if (_snapshot.status != RestTimerStatus.running) return;
    await _enterAlarming();
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  /// Shared by the live per-second ticker and by the lifecycle-resume check
  /// — both mean the process was alive at the moment of discovery (a cold
  /// relaunch never reaches this method; it is reconciled separately in
  /// [init]), so both start the alarm exactly the same way. No
  /// foreground-vs-background distinction here on purpose: per
  /// [didChangeAppLifecycleState]'s doc, a completion noticed on resume is
  /// exactly as real as one noticed while the screen was open.
  void _tick() {
    if (_snapshot.status != RestTimerStatus.running) return;
    final end = _snapshot.endEpochMs;
    if (end != null && _now().millisecondsSinceEpoch >= end) {
      _enterAlarming();
    } else {
      notifyListeners();
    }
  }

  /// Timer reaches zero -> ALARMING (spec §1/§5): stop counting down, start
  /// the looping audio + repeating vibration, and wait for Stop Alarm. This
  /// no longer goes straight to [RestTimerStatus.completed] — that status is
  /// now reached ONLY via [stopAlarm].
  Future<void> _enterAlarming() async {
    _stopTicker();
    _snapshot = _snapshot.copyWith(status: RestTimerStatus.alarming, endEpochMs: null);
    await _persist();
    // Cancel the scheduled system notification: the in-app alarm is now the
    // live, primary alert (audio + vibration + the Stop Alarm screen), so a
    // system notification popping over it moments later would just be a
    // redundant duplicate of what the athlete can already see and hear.
    unawaited(_notifications.cancel());
    await _startAlarmEffects();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      await _prefs?.setJson(_storageKey, _snapshot.toJson());
    } catch (e) {
      if (kDebugMode) debugPrint('[REST TIMER] persist failed (non-fatal): $e');
    }
  }

  @override
  void dispose() {
    // Not expected to actually run in production (this is a
    // process-lifetime singleton, same as `LocalStorageService.instance`),
    // but implemented correctly rather than left a no-op, for tests that
    // construct a scoped instance directly via `RestTimerController.debug(...)`.
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    _stopTicker();
    _alarmVibrationTimer?.cancel();
    _player?.dispose();
    super.dispose();
  }

  /// Test-only construction, mirroring the pattern every other controller in
  /// this codebase uses for injecting fakes (see e.g. `MealCheckinRepository`,
  /// `AssessmentController`). Never used by app code, which always goes
  /// through [instance].
  @visibleForTesting
  factory RestTimerController.debug({
    LocalStorageService? storage,
    AudioPlayer? player,
    RestTimerNotificationService? notifications,
    DateTime Function()? clock,
  }) =>
      RestTimerController._(
        storage: storage,
        player: player,
        notifications: notifications,
        clock: clock,
      );
}
