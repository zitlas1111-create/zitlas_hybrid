import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../dashboard_controller.dart';
import '../../models/health_status.dart';
import '../dashboard_visuals.dart';
import 'health_report_sheet.dart';

/// `#healthStatusMount` / `health-status.js`'s `renderCard()` — the
/// "❤️ How are you feeling today?" card, its Recovery Mode summary, and the
/// 7-day recovery timeline. Copy, status labels and ordering are exact.
class HealthStatusCard extends StatelessWidget {
  const HealthStatusCard({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DashboardController>();
    final today = controller.healthToday;
    final activeKey = today?.status ?? (controller.healthTodayGreat ? 'great' : null);

    return DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '❤️ How are you feeling today?',
            style: TextStyle(
              color: DashboardColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          const Text(
            'Your AI and Personal Coach will adjust today’s plan accordingly.',
            style: TextStyle(color: DashboardColors.textSecondary, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final status in healthStatuses)
                _StatusChip(
                  label: status.label,
                  active: activeKey == status.key,
                  tone: _toneFor(status.key),
                  onTap: () => showHealthReportSheet(context, controller, status),
                ),
              if (today != null)
                _StatusChip(
                  label: '✕ Clear Status',
                  active: false,
                  tone: _ChipTone.neutral,
                  onTap: () async {
                    await controller.clearHealthStatus();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Status cleared — today’s original plan is restored.'),
                      ),
                    );
                  },
                ),
            ],
          ),
          if (today != null) ...[
            const SizedBox(height: 14),
            _RecoveryPanel(adjustment: today),
          ] else if (controller.healthTodayGreat) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0x143A8F8B),
                border: Border.all(color: const Color(0x333A8F8B)),
                borderRadius: BorderRadius.circular(kDashboardRadiusSm),
              ),
              child: const Text(
                '😊 Logged: feeling great — full plan active.',
                style: TextStyle(
                  color: DashboardColors.hydrationTeal,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
          if (controller.healthHistory.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Timeline(history: controller.healthHistory),
          ],
        ],
      ),
    );
  }

  /// `STATUSES[].cls` — `active` / `active--warn` / `active--danger`.
  static _ChipTone _toneFor(String key) => switch (key) {
    'great' => _ChipTone.ok,
    'sick' || 'injured' => _ChipTone.danger,
    _ => _ChipTone.warn,
  };
}

enum _ChipTone { ok, warn, danger, neutral }

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.active,
    required this.tone,
    required this.onTap,
  });

  final String label;
  final bool active;
  final _ChipTone tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = switch (tone) {
      _ChipTone.ok => DashboardColors.success,
      _ChipTone.warn => DashboardColors.primary,
      _ChipTone.danger => DashboardColors.error,
      _ChipTone.neutral => DashboardColors.textMuted,
    };
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: active ? accent.withValues(alpha: 0.16) : DashboardColors.bgCardLight,
          border: Border.all(
            color: active ? accent.withValues(alpha: 0.55) : DashboardColors.border,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? accent : DashboardColors.textPrimary,
            fontSize: 12,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// `.hs-recovery` — today's applied adjustment.
class _RecoveryPanel extends StatelessWidget {
  const _RecoveryPanel({required this.adjustment});

  final HealthAdjustment adjustment;

  @override
  Widget build(BuildContext context) {
    final danger = adjustment.safety;
    final accent = danger ? DashboardColors.error : DashboardColors.primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(kDashboardRadiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '🛟 Today’s Recovery Mode — ${healthStatusLabel(adjustment.status)}',
            style: TextStyle(color: accent, fontSize: 13, fontWeight: FontWeight.w800),
          ),
          if (danger) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: DashboardColors.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                '⚠ Seek medical attention before exercising. Your coach has been notified.',
                style: TextStyle(
                  color: DashboardColors.error,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
            ),
          ],
          if (adjustment.workout != null) ...[
            const SizedBox(height: 8),
            _Row(label: 'Workout:', value: adjustment.workout!.title),
            const SizedBox(height: 4),
            ...adjustment.workout!.items.map(
              (i) => Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 2),
                child: Text(
                  '• $i',
                  style: const TextStyle(
                    color: DashboardColors.textSecondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ],
          if (adjustment.diet != null) ...[
            const SizedBox(height: 6),
            _Row(
              label: 'Diet:',
              value: '${adjustment.diet!.title} (today’s meals adjusted on the Diet page)',
            ),
          ],
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(
                  text: 'Steps: ',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                ),
                TextSpan(
                  text: '${adjustment.oldStepsGoal} → ',
                  style: const TextStyle(fontSize: 12),
                ),
                TextSpan(
                  text: adjustment.stepsGoalLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: DashboardColors.successDark,
                  ),
                ),
              ],
              style: const TextStyle(color: DashboardColors.textSecondary),
            ),
          ),
          const SizedBox(height: 3),
          const _Row(
            label: 'Streak:',
            value: 'protected — today counts as a Recovery Day, not a miss.',
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
          ),
          TextSpan(text: value, style: const TextStyle(fontSize: 12)),
        ],
        style: const TextStyle(color: DashboardColors.textSecondary, height: 1.35),
      ),
    );
  }
}

/// `.hs-timeline` — last 7 reports plus the sick/injured tally.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.history});

  final List<HealthHistoryEntry> history;

  @override
  Widget build(BuildContext context) {
    final recent = history.length > 7 ? history.sublist(history.length - 7) : history;
    final sickDays =
        history.where((h) => h.status == 'sick' || h.status == 'unwell').length;
    final injDays = history.where((h) => h.status == 'injured').length;
    final fmt = DateFormat('d MMM');

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        ...recent.map((h) {
          final parsed = DateTime.tryParse(h.date);
          final label = parsed == null ? h.date : fmt.format(parsed);
          return _Chip('${healthStatusIcons[h.status] ?? '•'} $label');
        }),
        if (sickDays > 0 || injDays > 0) _Chip('Σ $sickDays sick · $injDays injured'),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: DashboardColors.bgCardLight,
        border: Border.all(color: DashboardColors.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: const TextStyle(color: DashboardColors.textSecondary, fontSize: 11),
      ),
    );
  }
}
