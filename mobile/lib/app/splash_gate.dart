import 'dart:async';

import 'package:flutter/foundation.dart';

/// Releases the startup holding frame as soon as the first frame is up.
///
/// WAS: a 1200ms MINIMUM hold, so a branded logo screen could be read as
/// intentional. That is exactly the custom startup screen that has now been
/// removed — there is no logo left to give time to, so holding the app back
/// for it was pure waiting. [minimumDuration] is now zero: the gate opens on
/// the next event-loop turn and the router leaves `/splash` the moment auth
/// resolves.
///
/// The class is kept rather than deleted because two things still depend on
/// "has the app finished starting up": the router's redirect, and
/// `app.dart`'s deferral of a cold-start notification deep link until the
/// router exists. Both still work; neither now costs the user a second.
///
/// A [ChangeNotifier] because GoRouter's redirect is not re-evaluated on a bare
/// timer — the router merges this with `AuthState` as its `refreshListenable`,
/// so becoming ready triggers exactly one re-evaluation and the redirect away
/// from `/splash`.
class SplashGate extends ChangeNotifier {
  SplashGate._();

  static final SplashGate instance = SplashGate._();

  /// ZERO. There is no branded splash to hold for any more; the only thing the
  /// app legitimately waits on is the auth check, which the router gates on
  /// separately. A zero-duration timer still defers to the next event-loop
  /// turn, so the gate opens AFTER the first frame — which is what
  /// `app.dart`'s notification deferral relies on.
  static const minimumDuration = Duration.zero;

  bool _ready = false;
  Timer? _timer;

  /// Whether the app may leave the splash.
  ///
  /// Reading this LAZILY STARTS the clock if nobody has yet. `main()` starts it
  /// explicitly (so it runs concurrently with initialization, which is the
  /// point), but the router asks this question on its very first redirect — so
  /// self-starting here guarantees the gate can never leave the app stranded on
  /// the splash forever just because `start()` was missed on some entry path
  /// (a test harness, a future alternate `main`, an integration driver).
  bool get isReady {
    if (!_ready) start();
    return _ready;
  }

  /// Opens the gate on the next event-loop turn. Called once from `main()` BEFORE
  /// `runApp`, so the clock runs alongside initialization rather than after it.
  /// Idempotent — a second call is ignored, so a hot restart cannot stack
  /// timers or re-hold the splash.
  void start() {
    if (_ready || _timer != null) return;
    _timer = Timer(minimumDuration, () {
      _timer = null;
      _ready = true;
      if (kDebugMode) debugPrint('[SPLASH] startup gate open — routing unblocked');
      notifyListeners();
    });
  }

  /// Test seam: lets a widget test skip the hold entirely.
  @visibleForTesting
  void forceReadyForTest() {
    _timer?.cancel();
    _timer = null;
    _ready = true;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _ready = false;
  }
}
