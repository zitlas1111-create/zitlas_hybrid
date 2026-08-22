import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../dashboard_controller.dart';
import '../dashboard_visuals.dart';

/// `#resetGoalModal` confirm/cancel — on confirm, clears goal-scoped fields
/// (matches `clearAllSurveyData()`/`clearGoalData()`) then routes to the
/// assessment flow, same destination as `./ai-coach/ai-coach.html`.
Future<void> showResetGoalDialog(BuildContext context, DashboardController controller) {
  return showDialog<void>(
    context: context,
    builder: (context) => _ResetGoalDialog(controller: controller),
  );
}

class _ResetGoalDialog extends StatefulWidget {
  const _ResetGoalDialog({required this.controller});
  final DashboardController controller;

  @override
  State<_ResetGoalDialog> createState() => _ResetGoalDialogState();
}

class _ResetGoalDialogState extends State<_ResetGoalDialog> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: DashboardColors.bgCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Reset Your Goal?',
              style: TextStyle(
                color: DashboardColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'This clears your current goal and plan data so you can start a fresh '
              'assessment. This cannot be undone.',
              style: TextStyle(color: DashboardColors.textSecondary, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFFF3B30), Color(0xFFFF6B6B)],
                        ),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: _busy
                              ? null
                              : () async {
                                  setState(() => _busy = true);
                                  // Goal resets are metered server-side
                                  // (free 2/week, premium 5/week). A refusal
                                  // is a real answer, not a failure: say why
                                  // instead of dropping the athlete into the
                                  // assessment as if the reset had happened.
                                  final outcome =
                                      await widget.controller.resetGoal();
                                  if (!context.mounted) return;
                                  Navigator.of(context).pop();
                                  if (!outcome.allowed) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(outcome.message ??
                                            'Goal reset is not available '
                                                'right now.'),
                                      ),
                                    );
                                    return;
                                  }
                                  context.push('/assessment');
                                },
                          child: Center(
                            child: _busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text(
                                    'Reset',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
