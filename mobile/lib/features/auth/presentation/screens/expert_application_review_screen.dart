import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../auth_state.dart';
import '../auth_visuals.dart';
import '../widgets/auth_icons.dart';

/// Native rebuild of the `.grm-under-review` panel in `login.html`/`login.css`
/// — shown once, immediately after a Google sign-in chooses "Expert" in the
/// role picker (that path never creates an `experts/{uid}` doc, so there's
/// nothing yet for the real expert dashboard to render). The user continues
/// into the athlete dashboard while their application is pending — matches
/// production; not a bug.
class ExpertApplicationReviewScreen extends StatelessWidget {
  const ExpertApplicationReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final email = context.watch<AuthState>().profile?.email ?? '';

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
        systemStatusBarContrastEnforced: false,
      ),
      child: Scaffold(
      backgroundColor: AuthColors.bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
              decoration: BoxDecoration(
                color: AuthColors.cardSolid,
                borderRadius: BorderRadius.circular(kAuthRadiusXl),
                boxShadow: kAuthCardShadow,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: const BoxDecoration(
                      color: Color(0x1FFF8C00),
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: AuthIcon(AuthIconPaths.reviewClock, size: 22, color: AuthColors.orange),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Application Under Review',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AuthColors.ink,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Application submitted for $email',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AuthColors.ink, fontSize: 13.5),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'We will notify you via email once your account is approved. '
                    'This usually takes 1-2 business days.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AuthColors.muted, fontSize: 12.5, height: 1.6),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0x0F111827),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => context.go('/dashboard'),
                          child: const Center(
                            child: Text(
                              'Continue as User',
                              style: TextStyle(
                                color: AuthColors.ink,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}
