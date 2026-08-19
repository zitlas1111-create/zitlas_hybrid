import 'package:flutter/material.dart';

import '../../../../app/theme.dart';

/// The brief holding frame shown ONLY while Firebase's persisted-session check
/// is still resolving ([AuthStatus.unknown]).
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
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(backgroundColor: ZitlasColors.bgPrimary, body: SizedBox.expand());
  }
}
