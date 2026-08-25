import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../app/theme.dart';
import '../../auth_state.dart';

/// The brief holding frame shown while Firebase's persisted-session check is
/// still resolving ([AuthStatus.unknown]) — and now also while a signed-in
/// account's ROLE is still being resolved.
///
/// DELIBERATELY UNBRANDED. This used to be a full-screen animated ZITLAS logo
/// held for a minimum of 1200ms by `SplashGate` — a custom startup screen every
/// cold start had to sit through before the app appeared. That screen is gone:
/// the logo, the fade/scale animation and the artificial minimum have all been
/// removed, so the app now opens straight into the real screen.
///
/// Why this route still exists at all: the router cannot know whether to show
/// the dashboard or the login screen until auth resolves, and rendering login
/// first would flash the wrong screen at an already-signed-in user. So it
/// renders NOTHING but the background colour for the few hundred milliseconds
/// that check takes.
///
/// That colour is `android/app/src/main/res/values/colors.xml`'s
/// `zitlas_splash_bg`, identical to the native launch window's drawable — so
/// there is no visible transition between the OS launch frame and this frame,
/// and no perceptible extra screen before the app. Nothing is animated,
/// nothing is branded, and it is never a navigation destination (see
/// `_AppShellState`'s back handling and the router's redirect).
///
/// THE ONE THING IT DOES DRAW is the role-unresolved recovery state. The
/// router holds here rather than guessing a landing screen when
/// `GET /api/auth/role` could not be reached, so without this the app would
/// sit on a blank colour indefinitely. An expert must never be silently
/// downgraded to the athlete dashboard, but they must not be stranded either.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();

    // Signed in, retries exhausted, still no answer. Anything other than an
    // explicit retry here would mean guessing the account's role.
    if (auth.isAuthenticated && auth.roleResolutionFailed) {
      return const Scaffold(
        backgroundColor: ZitlasColors.bgPrimary,
        body: _RoleUnavailable(),
      );
    }

    return const Scaffold(
      backgroundColor: ZitlasColors.bgPrimary,
      body: SizedBox.expand(),
    );
  }
}

class _RoleUnavailable extends StatelessWidget {
  const _RoleUnavailable();

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthState>();
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "We couldn't verify your account",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: ZitlasColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              // Deliberately does not name a role: we do not know one yet, and
              // saying "expert" or "athlete" here would be the same guess the
              // router refuses to make.
              'Check your connection and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: ZitlasColors.textSecondary),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: auth.retryRoleResolution,
              child: const Text('Try again'),
            ),
            TextButton(
              onPressed: auth.signOut,
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}
