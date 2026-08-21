import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../auth/auth_state.dart';
import '../../dashboard_controller.dart';
import '../dashboard_visuals.dart';

/// `.greeting-section` — `initGreeting()` in dashboard.js: time-of-day line
/// + first name (falls back to "User! 👋" exactly like the website).
class GreetingSection extends StatelessWidget {
  const GreetingSection({super.key});

  String get _timeGreeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning,';
    if (hour < 17) return 'Good Afternoon,';
    return 'Good Evening,';
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DashboardController>();
    final authName = context.watch<AuthState>().profile?.name;
    final rawName = controller.displayName ?? authName;
    final name = rawName?.trim().split(RegExp(r'\s+')).first;
    final greetingName = (name == null || name.isEmpty) ? 'User! 👋' : '$name! 👋';

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _timeGreeting,
            style: const TextStyle(
              color: DashboardColors.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            greetingName,
            style: const TextStyle(
              color: DashboardColors.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.3,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Discipline today, victory tomorrow.',
            style: TextStyle(color: DashboardColors.textMuted, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
