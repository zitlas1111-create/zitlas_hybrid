import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/zitlas_tokens.dart';
import '../../auth/auth_state.dart';
import '../../payments/add_funds_flow.dart';
import '../../payments/data/wallet_repository.dart';
import '../../payments/presentation/widgets/add_funds_sheet.dart' show kMinTopUp;
import '../../payments/presentation/widgets/insufficient_balance_card.dart';
import '../coaching_programs.dart';
import '../data/coaching_programs_repository.dart';
import '../models/program_offer.dart';
import 'coaching_programs_controller.dart';

/// `/coaching-programs[?expertId=<id>]` — exported so the app router and the
/// tests register exactly the same route. [repository] is for tests only.
GoRoute coachingProgramsRoute({CoachingProgramsRepository? repository}) => GoRoute(
      path: kCoachingProgramsPath,
      builder: (context, state) => CoachingProgramsScreen(
        expertId: state.uri.queryParameters['expertId'],
        repository: repository,
      ),
    );

/// PERSONAL COACHING PROGRAMS — where Personal Coaching starts.
///
/// Each program shows the selected expert's OWN price, read from the server
/// (never a number in the app). Get Started sends a request; once the expert
/// accepts, Pay & Start Program pays the price the SERVER recorded, in full,
/// from the ZITLAS Wallet, and the program starts. A short wallet shows the
/// existing insufficient-balance card with Add Funds (the existing flow) —
/// Razorpay is never opened just because the wallet was short, and the
/// program is never paid automatically after a top-up.
class CoachingProgramsScreen extends StatefulWidget {
  const CoachingProgramsScreen({
    super.key,
    this.expertId,
    this.programs = kCoachingPrograms,
    this.repository,
    this.walletRepository,
    this.addFundsFlow,
  });

  /// The expert whose Personal Coach button opened this screen. Without one
  /// there is nothing to price, and every program is unavailable.
  final String? expertId;

  final List<CoachingProgram> programs;

  /// Injectable for tests — the app talks to the live backend.
  final CoachingProgramsRepository? repository;

  /// Injectable for tests — the existing wallet and Add Funds flow.
  final WalletRepository? walletRepository;
  final AddFundsFlow? addFundsFlow;

  @override
  State<CoachingProgramsScreen> createState() => _CoachingProgramsScreenState();
}

class _CoachingProgramsScreenState extends State<CoachingProgramsScreen> {
  late final CoachingProgramsController _controller;

  /// Created on first Add Funds only — most visits never need them.
  WalletRepository? _wallet;
  AddFundsFlow? _flow;
  bool _ownsFlow = false;
  bool _addingFunds = false;

  @override
  void initState() {
    super.initState();
    final id = widget.expertId?.trim();
    final hasExpert = id != null && id.isNotEmpty;
    _controller = CoachingProgramsController(
      expertId: hasExpert ? id : null,
      repository: hasExpert ? (widget.repository ?? CoachingProgramsRepository.live()) : null,
    )..load();
  }

  @override
  void dispose() {
    _controller.dispose();
    if (_ownsFlow) _flow?.dispose();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
  }

  Future<void> _getStarted(CoachingProgram program, int pricePaise) async {
    final expertName = _controller.offer?.expertName ?? 'your expert';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('coachingProgramConfirm'),
        title: Text('Request the ${program.title}?'),
        content: Text(
          '${formatProgramPrice(pricePaise)} · ${program.durationLabel}\n\n'
          "You won't be charged now. $expertName will review your request first.",
        ),
        actions: [
          TextButton(
            key: const Key('coachingProgramConfirmCancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('coachingProgramConfirmSend'),
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: ZitlasTokens.primary),
            child: const Text('Send Request'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final outcome = await _controller.requestProgram(program.id);
    if (mounted) _snack(outcome.message);
  }

  /// Pay & Start Program. The server charges its own price snapshot.
  Future<void> _payAndStart() async {
    final outcome = await _controller.payAndStart();
    if (!mounted || outcome.message.isEmpty) return;
    _snack(outcome.message);
  }

  /// Add Funds from the insufficient-balance card — the EXISTING flow, pre-
  /// filled with what the program is short by. After a CONFIRMED credit the
  /// wallet is re-read from the server; the program is not paid until the
  /// athlete taps Pay & Start Program again.
  Future<void> _addFunds() async {
    final short = _controller.shortfall;
    if (short == null || _addingFunds) return;
    final profile = context.read<AuthState>().profile;
    final uid = profile?.uid;
    if (uid == null) {
      _snack('Please sign in again to continue.');
      return;
    }
    final wallet = _wallet ??= widget.walletRepository ?? WalletRepository();
    var flow = _flow ?? widget.addFundsFlow;
    if (flow == null) {
      flow = AddFundsFlow(repository: wallet);
      _ownsFlow = true;
    }
    _flow = flow;
    setState(() => _addingFunds = true);
    try {
      final outcome = await runAddFunds(
        context,
        flow: flow,
        uid: uid,
        email: profile?.email,
        suggestedAmount: math.max(kMinTopUp, short.shortfallRupees.ceil()),
        reportCredited: false,
      );
      if (outcome == null || !outcome.credited || !mounted) return;
      final covered =
          await _controller.onFundsAdded(() async => (await wallet.fetch(uid)).available);
      if (mounted) _snack(covered ? kProgramFundsAddedReady : kProgramFundsAddedShort);
    } finally {
      if (mounted) setState(() => _addingFunds = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZitlasTokens.bgStart,
      appBar: AppBar(
        backgroundColor: ZitlasTokens.bgStart,
        surfaceTintColor: Colors.transparent,
        foregroundColor: ZitlasTokens.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final c = _controller;
          final blocking = c.openRequest;
          final payment = _PaymentActions(
            paying: c.paying,
            shortfall: c.shortfall,
            addingFunds: _addingFunds,
            onPay: _payAndStart,
            onAddFunds: _addFunds,
          );
          return ListView(
            key: const Key('coachingProgramsList'),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              const _Header(),
              if (c.state == ProgramsLoadState.failed) ...[
                const SizedBox(height: 14),
                _LoadError(onRetry: c.load),
              ],
              const SizedBox(height: 20),
              for (final program in widget.programs) ...[
                _ProgramCard(
                  program: program,
                  loading: c.state == ProgramsLoadState.loading,
                  pricePaise: c.priceFor(program.id),
                  request: c.request?.programId == program.id ? c.request : null,
                  blockedBy: blocking != null && blocking.programId != program.id ? blocking : null,
                  submitting: c.submittingProgramId == program.id,
                  busy: c.submittingProgramId != null || c.paying,
                  now: c.now(),
                  payment: payment,
                  onGetStarted: (price) => _getStarted(program, price),
                ),
                const SizedBox(height: 24),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// The accepted card's payment state and actions, passed down as one.
class _PaymentActions {
  const _PaymentActions({
    required this.paying,
    required this.shortfall,
    required this.addingFunds,
    required this.onPay,
    required this.onAddFunds,
  });

  final bool paying;
  final InsufficientWalletBalance? shortfall;
  final bool addingFunds;
  final VoidCallback onPay;
  final VoidCallback onAddFunds;
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ZITLAS PERSONAL COACHING',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
              color: ZitlasTokens.freshGreen,
            ),
          ),
          const SizedBox(height: 6),
          Semantics(
            header: true,
            child: const Text(
              'Personal Coaching Programs',
              style: TextStyle(
                fontSize: 26,
                height: 1.15,
                fontWeight: FontWeight.w800,
                color: ZitlasTokens.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Work 1:1 with a ZITLAS expert on your nutrition. '
            'Choose the program that fits your goal.',
            style: TextStyle(fontSize: 13.5, height: 1.45, color: ZitlasTokens.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('coachingProgramsLoadError'),
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: ZitlasTokens.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              "Couldn't load this expert's prices.",
              style: TextStyle(fontSize: 13, color: ZitlasTokens.textPrimary),
            ),
          ),
          TextButton(
            key: const Key('coachingProgramsRetry'),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _ProgramCard extends StatelessWidget {
  const _ProgramCard({
    required this.program,
    required this.loading,
    required this.pricePaise,
    required this.request,
    required this.blockedBy,
    required this.submitting,
    required this.busy,
    required this.now,
    required this.payment,
    required this.onGetStarted,
  });

  final CoachingProgram program;
  final bool loading;

  /// The expert's server-side price; null = "Currently unavailable".
  final int? pricePaise;

  /// The athlete's request for THIS program, if any.
  final ProgramRequest? request;

  /// Another program with this expert that is still open or running.
  final ProgramRequest? blockedBy;
  final bool submitting;
  final bool busy;
  final DateTime now;
  final _PaymentActions payment;
  final ValueChanged<int> onGetStarted;

  @override
  Widget build(BuildContext context) {
    final r = request;
    // Nothing to start while this program is waiting (on the expert or on
    // payment) or already running.
    final hideStart = r != null && (r.isOpen || r.isRunning(now));
    final price = pricePaise;
    final canStart = !loading && price != null && blockedBy == null && !busy;
    return Container(
      key: Key('coachingProgram_${program.id}'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: ZitlasTokens.borderSub),
        boxShadow: kZitlasCardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ProgramArtwork(program: program),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        program.title,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: ZitlasTokens.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _DurationChip(label: program.durationLabel),
                  ],
                ),
                const SizedBox(height: 8),
                _PriceLine(programId: program.id, loading: loading, pricePaise: price),
                const SizedBox(height: 8),
                Text(
                  program.description,
                  style: const TextStyle(
                    fontSize: 13.5,
                    height: 1.45,
                    color: ZitlasTokens.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'WHAT YOU GET',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                    color: ZitlasTokens.textMuted,
                  ),
                ),
                const SizedBox(height: 10),
                for (final highlight in program.highlights) _Highlight(text: highlight),
                const SizedBox(height: 18),
                if (r != null) ...[
                  if (r.awaitingPayment)
                    _PaymentPanel(program: program, request: r, actions: payment)
                  else
                    _RequestStatus(programId: program.id, request: r, now: now),
                  if (!hideStart) const SizedBox(height: 12),
                ],
                if (!hideStart) ...[
                  if (blockedBy != null) ...[
                    Text(
                      blockedBy!.status == ProgramRequestStatus.active
                          ? kProgramOtherRunning
                          : kProgramOtherRequestOpen,
                      style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textMuted),
                    ),
                    const SizedBox(height: 8),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: Key('coachingProgramGetStarted_${program.id}'),
                      onPressed: canStart ? () => onGetStarted(price) : null,
                      style: _primaryButtonStyle,
                      child: submitting
                          ? const _ButtonSpinner()
                          : const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('Get Started'),
                                SizedBox(width: 8),
                                Icon(Icons.arrow_forward_rounded, size: 18),
                              ],
                            ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final ButtonStyle _primaryButtonStyle = FilledButton.styleFrom(
  backgroundColor: ZitlasTokens.primary,
  foregroundColor: Colors.white,
  disabledBackgroundColor: ZitlasTokens.border,
  disabledForegroundColor: ZitlasTokens.textMuted,
  padding: const EdgeInsets.symmetric(vertical: 15),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
);

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
    );
  }
}

/// The expert's price, or "Currently unavailable" — never ₹0.
class _PriceLine extends StatelessWidget {
  const _PriceLine({required this.programId, required this.loading, required this.pricePaise});

  final String programId;
  final bool loading;
  final int? pricePaise;

  @override
  Widget build(BuildContext context) {
    final price = pricePaise;
    final Widget child;
    if (loading) {
      child = const Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: ZitlasTokens.primary),
          ),
          SizedBox(width: 8),
          Text('Loading price…', style: TextStyle(fontSize: 13, color: ZitlasTokens.textMuted)),
        ],
      );
    } else if (price != null) {
      child = Text(
        formatProgramPrice(price),
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          color: ZitlasTokens.primary,
        ),
      );
    } else {
      child = const Text(
        kProgramUnavailable,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: ZitlasTokens.textMuted),
      );
    }
    return KeyedSubtree(key: Key('coachingProgramPrice_$programId'), child: child);
  }
}

/// Accepted by the expert: the price the SERVER recorded, and Pay & Start.
/// A short wallet adds the existing insufficient-balance card with Add Funds.
class _PaymentPanel extends StatelessWidget {
  const _PaymentPanel({required this.program, required this.request, required this.actions});

  final CoachingProgram program;
  final ProgramRequest request;
  final _PaymentActions actions;

  @override
  Widget build(BuildContext context) {
    final price = request.pricePaise;
    final shortfall = actions.shortfall;
    return Container(
      key: Key('coachingProgramPayment_${program.id}'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZitlasTokens.freshGreen.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.check_circle_rounded, size: 20, color: ZitlasTokens.freshGreen),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  kProgramAcceptedTitle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: ZitlasTokens.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _Detail(label: 'Program', value: program.title),
          _Detail(
            key: Key('coachingProgramAmount_${program.id}'),
            label: 'Amount',
            value: price == null ? '—' : formatProgramPrice(price),
          ),
          const SizedBox(height: 6),
          const Text(
            kProgramAcceptedBody,
            style: TextStyle(fontSize: 12.5, height: 1.4, color: ZitlasTokens.textSecondary),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: Key('coachingProgramPay_${program.id}'),
              onPressed: (actions.paying || price == null) ? null : actions.onPay,
              style: _primaryButtonStyle,
              child: actions.paying ? const _ButtonSpinner() : const Text(kProgramPayLabel),
            ),
          ),
          if (shortfall != null) ...[
            const SizedBox(height: 12),
            InsufficientBalanceCard(
              shortfall: shortfall,
              onAddFunds: actions.onAddFunds,
              busy: actions.addingFunds,
              message: kProgramShortfallMessage,
              shortfallLabel: 'Need',
            ),
          ],
        ],
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary)),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: ZitlasTokens.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Where a request stands when there is nothing to pay: waiting on the
/// expert, declined, or a paid program (running or ended).
class _RequestStatus extends StatelessWidget {
  const _RequestStatus({required this.programId, required this.request, required this.now});

  final String programId;
  final ProgramRequest request;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final started = request.startedAt;
    final ends = request.endsAt;
    final paid = request.amountPaidPaise;
    final (IconData icon, Color color, String title, String body) = switch (request.status) {
      ProgramRequestStatus.active when request.isRunning(now) => (
          Icons.play_circle_fill_rounded,
          ZitlasTokens.freshGreen,
          kProgramActiveTitle,
          [
            if (started != null) 'Started ${formatProgramDate(started)}',
            if (ends != null) 'Ends ${formatProgramDate(ends)}',
          ].join(' · '),
        ),
      ProgramRequestStatus.active => (
          Icons.flag_rounded,
          ZitlasTokens.textMuted,
          'Program ended',
          ends == null
              ? 'You can start a new program.'
              : 'Ended ${formatProgramDate(ends)}. You can start a new program.',
        ),
      ProgramRequestStatus.declined => (
          Icons.cancel_rounded,
          ZitlasTokens.danger,
          kProgramDeclinedTitle,
          kProgramDeclinedBody,
        ),
      _ => (
          Icons.hourglass_top_rounded,
          ZitlasTokens.fitnessOrange,
          kProgramPendingTitle,
          kProgramPendingBody,
        ),
    };
    final price = request.pricePaise;
    final pending = request.status == ProgramRequestStatus.pendingExpertAcceptance;
    return Container(
      key: Key('coachingProgramStatus_$programId'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: ZitlasTokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: const TextStyle(fontSize: 12.5, height: 1.4, color: ZitlasTokens.textSecondary),
                ),
                if (pending && price != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Program price: ${formatProgramPrice(price)}',
                    style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary),
                  ),
                ],
                if (request.isRunning(now) && paid != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Paid ${formatProgramPrice(paid)} from your ZITLAS Wallet',
                    style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgramArtwork extends StatelessWidget {
  const _ProgramArtwork({required this.program});

  final CoachingProgram program;

  /// All three banners are 1983 × 793. The card keeps that exact shape, so
  /// nothing in the artwork — the program name is part of it — is cropped.
  static const aspectRatio = 1983 / 793;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Decode at the size it is shown rather than the 1983px original:
          // three full-size banners would hold ~19 MB of pixels for one screen.
          final width = constraints.maxWidth;
          final cacheWidth = width.isFinite
              ? (width * MediaQuery.devicePixelRatioOf(context)).round().clamp(1, 1983).toInt()
              : null;
          return Image.asset(
            program.imageAsset,
            key: Key('coachingProgramImage_${program.id}'),
            fit: BoxFit.cover,
            cacheWidth: cacheWidth,
            semanticLabel: '${program.title} artwork',
            errorBuilder: (_, _, _) => _ArtworkFallback(title: program.title),
          );
        },
      ),
    );
  }
}

/// Only if an image ever fails to load — the card stays readable.
class _ArtworkFallback extends StatelessWidget {
  const _ArtworkFallback({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [ZitlasTokens.primaryDark, ZitlasTokens.primary],
        ),
      ),
      child: Center(
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }
}

class _DurationChip extends StatelessWidget {
  const _DurationChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: ZitlasTokens.freshGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.schedule_rounded, size: 13, color: ZitlasTokens.primary),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: ZitlasTokens.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Highlight extends StatelessWidget {
  const _Highlight({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.check_circle_rounded, size: 18, color: ZitlasTokens.freshGreen),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13.5, height: 1.35, color: ZitlasTokens.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
