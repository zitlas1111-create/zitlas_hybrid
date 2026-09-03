import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../data/trial_report_repository.dart';
import '../../models/trial_report.dart';

/// Trial Report History — every completed coaching engagement this athlete
/// has a stored report for, newest first.
///
/// WHY THIS SCREEN EXISTS. `personal_coaching/{athleteId}` is overwritten
/// when a new engagement starts, so once an athlete begins their next
/// coaching engagement the previous `requestId` is no longer discoverable
/// from client-readable data — even though `trial_reports/{oldRequestId}` is
/// still safely stored. `GET /api/trial-reports` is the only way to reach
/// those, and this screen is its only consumer.
///
/// IT CALCULATES NOTHING, and it reconstructs nothing. The rows are the
/// summaries the backend returned; tapping one opens the existing detail
/// screen, which fetches the immutable snapshot by id. Nothing here reads
/// `personal_coaching` or derives a historical report from coaching data.
class TrialReportHistoryScreen extends StatefulWidget {
  const TrialReportHistoryScreen({super.key, this.repository});

  /// Injectable for tests only. Production builds the default, which talks to
  /// the real API — the screen has no other data source and never falls back
  /// to reading coaching documents.
  final TrialReportRepository? repository;

  @override
  State<TrialReportHistoryScreen> createState() =>
      _TrialReportHistoryScreenState();
}

class _TrialReportHistoryScreenState extends State<TrialReportHistoryScreen> {
  late final TrialReportRepository _repository =
      widget.repository ?? TrialReportRepository();
  late Future<List<TrialReportSummary>> _future;

  @override
  void initState() {
    super.initState();
    _future = _repository.fetchHistory();
  }

  void _reload() {
    // Block body, NOT `setState(() => _future = ...)`. An arrow body returns
    // the assigned Future, and setState asserts its callback returned nothing
    // — so the arrow form fired the request but threw before rebuilding,
    // leaving Retry visibly dead in debug builds.
    setState(() {
      _future = _repository.fetchHistory();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZitlasTokens.bgPrimary,
      appBar: AppBar(
        title: const Text('Trial Report History'),
        backgroundColor: ZitlasTokens.bgPrimary,
        foregroundColor: ZitlasTokens.textPrimary,
        elevation: 0,
      ),
      body: FutureBuilder<List<TrialReportSummary>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _HistoryMessage(
              icon: Icons.cloud_off_rounded,
              title: 'Could not load your reports',
              body: 'Check your connection and try again.',
              onRetry: _reload,
            );
          }
          final reports = snapshot.data ?? const <TrialReportSummary>[];
          if (reports.isEmpty) {
            // Not an error and not a failure — most athletes simply have no
            // completed coaching engagements yet.
            return const _HistoryMessage(
              icon: Icons.history_rounded,
              title: 'No reports yet',
              body: 'When a Personal Coaching engagement finishes, its summary '
                  'will appear here.',
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              itemCount: reports.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) =>
                  _HistoryRow(summary: reports[index]),
            ),
          );
        },
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.summary});

  final TrialReportSummary summary;

  @override
  Widget build(BuildContext context) {
    final period = _period(summary.startDate, summary.endDate);
    final days = summary.trialDurationDays;

    return Material(
      color: ZitlasTokens.bgCard,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        // Reuses the EXISTING detail route — no second detail screen, and the
        // persisted snapshot stays the single source of truth for contents.
        onTap: () => context.push('/trial-report/${summary.requestId}'),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: ZitlasTokens.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            summary.coachName ?? 'Personal Coaching',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: ZitlasTokens.textPrimary),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _Chip(
                          label: summary.isFreeTrial ? 'Trial' : 'Coaching',
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (period != null)
                      Text(period,
                          style: const TextStyle(
                              fontSize: 13,
                              color: ZitlasTokens.textSecondary)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (days != null) '$days days',
                        if (summary.engagementStatus != null)
                          _statusLabel(summary.engagementStatus!),
                      ].join(' · '),
                      style: const TextStyle(
                          fontSize: 12, color: ZitlasTokens.textMuted),
                    ),
                    if (summary.generatedAt != null) ...[
                      const SizedBox(height: 2),
                      Text('Report ready ${_shortDate(summary.generatedAt!)}',
                          style: const TextStyle(
                              fontSize: 12, color: ZitlasTokens.textMuted)),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: ZitlasTokens.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: ZitlasTokens.bgCardLight,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: ZitlasTokens.textSecondary)),
      );
}

class _HistoryMessage extends StatelessWidget {
  const _HistoryMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 44, color: ZitlasTokens.textMuted),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: ZitlasTokens.textPrimary)),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: ZitlasTokens.textSecondary)),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}

String _statusLabel(String status) => switch (status) {
      'expired' => 'Completed',
      'ended' => 'Ended early',
      _ => status,
    };

String? _period(String? start, String? end) {
  final from = start == null ? null : DateTime.tryParse(start);
  final to = end == null ? null : DateTime.tryParse(end);
  if (from == null && to == null) return null;
  if (from == null) return 'until ${_shortDate(end!)}';
  if (to == null) return 'from ${_shortDate(start!)}';
  return '${_shortDate(start!)} – ${_shortDate(end!)}';
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _shortDate(String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final local = parsed.toLocal();
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}
