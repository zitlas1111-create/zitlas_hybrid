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
/// (never a number in the app). Get Started is never a dead end: with no
/// expert chosen — or one who doesn't offer that program — it first opens
/// "choose your expert" (the approved experts who offer it, at their server
/// prices). Then the athlete reviews and sends the request; once the expert
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

  /// The expert whose Personal Coach button opened this screen. Without one,
  /// Get Started asks the athlete to choose an expert first.
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

  /// Set while one Get Started flow is open, so a double tap starts one flow.
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    final id = widget.expertId?.trim();
    final hasExpert = id != null && id.isNotEmpty;
    _controller = CoachingProgramsController(
      expertId: hasExpert ? id : null,
      // Always there: without an expert, Get Started still needs the server
      // to list who offers a program. No call is made until it is tapped.
      repository: widget.repository ?? CoachingProgramsRepository.live(),
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

  /// GET STARTED — the existing request flow for [program]:
  ///   choose an expert (when none is chosen, or this one doesn't offer it)
  ///   -> review the program at that expert's SERVER price -> Send Request.
  /// Nothing is charged here; paying comes after the expert accepts.
  Future<void> _getStarted(CoachingProgram program) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final c = _controller;
      if (c.expertId == null || c.priceFor(program.id) == null) {
        final chosen = await _chooseExpert(program);
        if (chosen == null || !mounted) return;
        await c.selectExpert(chosen.expertId);
        if (!mounted) return;
        if (c.state != ProgramsLoadState.ready) {
          _snack(kProgramExpertLoadFailed);
          return;
        }
        // The server knows this athlete's requests with that expert: one
        // already waiting (or running) is shown on its card, never duplicated.
        final open = c.openRequest;
        if (open != null) {
          if (open.programId == program.id) {
            _snack(open.isOpen ? kProgramAlreadyRequested : kProgramOtherRunning);
          } else {
            _snack(open.status == ProgramRequestStatus.active
                ? kProgramOtherRunning
                : kProgramOtherRequestOpen);
          }
          return;
        }
      }
      final price = c.priceFor(program.id);
      if (price == null) {
        final who = c.offer?.expertName ?? 'This expert';
        _snack("$who doesn't offer the ${program.title} right now. Choose another expert.");
        return;
      }
      await _confirmAndRequest(program, price);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// "Choose your expert" — the approved experts who offer [program], each at
  /// their own server price. Returns the chosen one; nothing is sent here.
  Future<ProgramExpertOption?> _chooseExpert(CoachingProgram program) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;
    return showModalBottomSheet<ProgramExpertOption>(
      context: context,
      isScrollControlled: true,
      backgroundColor: ZitlasTokens.bgCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: _ExpertPickerSheet(
          program: program,
          load: () => _controller.expertsFor(program.id),
        ),
      ),
    );
  }

  /// Review, then send. The request carries only the expert and the program;
  /// the server decides the price and records it on the request.
  Future<void> _confirmAndRequest(CoachingProgram program, int pricePaise) async {
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
              if (c.offer != null) ...[
                const SizedBox(height: 10),
                _ExpertLine(name: c.offer!.expertName),
              ],
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
                  hasExpert: c.expertId != null,
                  failed: c.state == ProgramsLoadState.failed,
                  submitting: c.submittingProgramId == program.id,
                  busy: c.submittingProgramId != null || c.paying || _starting,
                  now: c.now(),
                  payment: payment,
                  onGetStarted: () => _getStarted(program),
                  expertName: c.offer?.expertName,
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
    required this.hasExpert,
    required this.failed,
    required this.submitting,
    required this.busy,
    required this.now,
    required this.payment,
    required this.onGetStarted,
    this.expertName,
  });

  final CoachingProgram program;
  final bool loading;

  /// The expert's server-side price; null = "Currently unavailable".
  final int? pricePaise;

  /// The athlete's request for THIS program, if any.
  final ProgramRequest? request;

  /// Another program with this expert that is still open or running.
  final ProgramRequest? blockedBy;

  /// An expert is chosen (so an unpriced program means THEY don't offer it).
  final bool hasExpert;

  /// That expert's prices could not be loaded — Retry is shown instead.
  final bool failed;
  final bool submitting;
  final bool busy;
  final DateTime now;
  final _PaymentActions payment;
  final VoidCallback onGetStarted;

  /// Whose program this is — shown on a paid program's details.
  final String? expertName;

  @override
  Widget build(BuildContext context) {
    final r = request;
    // Nothing to start while this program is waiting (on the expert or on
    // payment) or already running.
    final hideStart = r != null && (r.isOpen || r.isRunning(now));
    final price = pricePaise;
    // Never a dead end: with no expert chosen — or one who doesn't offer this
    // program — Get Started opens "choose your expert". Only a load that is
    // running or failed, another open program, or a flow already under way
    // disables it.
    final canStart = !loading && !failed && blockedBy == null && !busy;
    final chooseAnother = hasExpert && !loading && !failed && price == null;
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
                _PriceLine(
                  programId: program.id,
                  loading: loading,
                  pricePaise: price,
                  hasExpert: hasExpert,
                ),
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
                    _RequestStatus(program: program, request: r, now: now, expertName: expertName),
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
                      onPressed: canStart ? onGetStarted : null,
                      style: _primaryButtonStyle,
                      child: submitting
                          ? const _ButtonSpinner()
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(chooseAnother ? kProgramChooseAnotherExpert : 'Get Started'),
                                const SizedBox(width: 8),
                                const Icon(Icons.arrow_forward_rounded, size: 18),
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
  const _PriceLine({
    required this.programId,
    required this.loading,
    required this.pricePaise,
    this.hasExpert = true,
  });

  final String programId;
  final bool loading;
  final int? pricePaise;

  /// False before an expert is chosen: there is no price to show YET.
  final bool hasExpert;

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
      child = Text(
        hasExpert ? kProgramUnavailable : kProgramChooseExpertToPrice,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: ZitlasTokens.textMuted),
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
/// expert, declined, or a paid program — running, ended or completed — with
/// the SERVER's program, expert, amount and dates (the app computes none).
class _RequestStatus extends StatelessWidget {
  const _RequestStatus({
    required this.program,
    required this.request,
    required this.now,
    this.expertName,
  });

  final CoachingProgram program;
  final ProgramRequest request;
  final DateTime now;

  /// The offer's expert name, used when the request itself carries none.
  final String? expertName;

  @override
  Widget build(BuildContext context) {
    final started = request.startedAt;
    final ends = request.endsAt;
    final paid = request.amountPaidPaise;
    final running = request.isRunning(now);
    final completed = request.status == ProgramRequestStatus.completed;
    final paidProgram = request.status == ProgramRequestStatus.active || completed;
    final (IconData icon, Color color, String title, String body) = switch (request.status) {
      ProgramRequestStatus.active when running => (
          Icons.play_circle_fill_rounded,
          ZitlasTokens.freshGreen,
          kProgramActiveTitle,
          '',
        ),
      ProgramRequestStatus.active || ProgramRequestStatus.completed => (
          Icons.flag_rounded,
          ZitlasTokens.textMuted,
          completed ? kProgramCompletedTitle : kProgramEndedTitle,
          'You can start a new program.',
        ),
      ProgramRequestStatus.declined => (
          Icons.cancel_rounded,
          ZitlasTokens.danger,
          kProgramDeclinedTitle,
          kProgramDeclinedBody,
        ),
      ProgramRequestStatus.pendingExpertAcceptance => (
          Icons.hourglass_top_rounded,
          ZitlasTokens.fitnessOrange,
          kProgramPendingTitle,
          kProgramPendingBody,
        ),
      _ => (
          Icons.help_outline_rounded,
          ZitlasTokens.textMuted,
          kProgramStatusUnknownTitle,
          kProgramStatusUnknownBody,
        ),
    };
    final price = request.pricePaise;
    final pending = request.status == ProgramRequestStatus.pendingExpertAcceptance;
    return Container(
      key: Key('coachingProgramStatus_${program.id}'),
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
                if (body.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    body,
                    style: const TextStyle(fontSize: 12.5, height: 1.4, color: ZitlasTokens.textSecondary),
                  ),
                ],
                if (pending && price != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Program price: ${formatProgramPrice(price)}',
                    style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary),
                  ),
                ],
                if (paidProgram) ...[
                  const SizedBox(height: 8),
                  _Detail(label: 'Program', value: program.title),
                  _Detail(label: 'Expert', value: request.expertName ?? expertName ?? '—'),
                  _Detail(
                    key: Key('coachingProgramPaid_${program.id}'),
                    label: 'Amount Paid',
                    value: paid == null ? '—' : formatProgramPrice(paid),
                  ),
                  _Detail(
                    key: Key('coachingProgramStart_${program.id}'),
                    label: 'Start Date',
                    value: started == null ? '—' : formatProgramDate(started),
                  ),
                  _Detail(
                    key: Key('coachingProgramEnd_${program.id}'),
                    label: 'End Date',
                    value: ends == null ? '—' : formatProgramDate(ends),
                  ),
                  _Detail(
                    key: Key('coachingProgramState_${program.id}'),
                    label: 'Status',
                    value: running ? 'Active' : (completed ? 'Completed' : 'Ended'),
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

/// Whose prices these are — shown once an expert is known.
class _ExpertLine extends StatelessWidget {
  const _ExpertLine({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('coachingProgramsExpert'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          const Icon(Icons.person_rounded, size: 16, color: ZitlasTokens.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Your expert: $name',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: ZitlasTokens.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Choose your expert" — the approved experts who offer [program], each at
/// their OWN server-side price. Pops with the chosen one; sends nothing.
class _ExpertPickerSheet extends StatefulWidget {
  const _ExpertPickerSheet({required this.program, required this.load});

  final CoachingProgram program;
  final Future<List<ProgramExpertOption>> Function() load;

  @override
  State<_ExpertPickerSheet> createState() => _ExpertPickerSheetState();
}

class _ExpertPickerSheetState extends State<_ExpertPickerSheet> {
  late Future<List<ProgramExpertOption>> _experts = widget.load();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        key: const Key('programExpertPicker'),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              kProgramPickExpertTitle,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.program.title} · ${widget.program.durationLabel}. '
              "You'll review the price before anything is sent.",
              style: const TextStyle(fontSize: 12.5, height: 1.4, color: ZitlasTokens.textSecondary),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: FutureBuilder<List<ProgramExpertOption>>(
                future: _experts,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: CircularProgressIndicator(color: ZitlasTokens.primary)),
                    );
                  }
                  if (snap.hasError) {
                    final error = snap.error;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          error is ProgramRequestException ? error.message : kProgramExpertsLoadFailed,
                          key: const Key('programExpertPickerError'),
                          style: const TextStyle(fontSize: 13, color: ZitlasTokens.textPrimary),
                        ),
                        TextButton(
                          key: const Key('programExpertPickerRetry'),
                          onPressed: () {
                            final next = widget.load();
                            setState(() {
                              _experts = next;
                            });
                          },
                          child: const Text('Retry'),
                        ),
                      ],
                    );
                  }
                  final experts = snap.data ?? const <ProgramExpertOption>[];
                  if (experts.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        kProgramNoExperts,
                        key: Key('programExpertPickerEmpty'),
                        style: TextStyle(fontSize: 13, color: ZitlasTokens.textSecondary),
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: experts.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _ExpertRow(
                      expert: experts[i],
                      onSelect: () => Navigator.of(context).pop(experts[i]),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One expert in "choose your expert": photo (or initials), name, what they
/// work on, their SERVER price for this program, and Select.
class _ExpertRow extends StatelessWidget {
  const _ExpertRow({required this.expert, required this.onSelect});

  final ProgramExpertOption expert;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final spec = expert.specialization;
    final areas = expert.expertise.take(3).join(' · ');
    return InkWell(
      key: Key('programExpert_${expert.expertId}'),
      onTap: onSelect,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            _ExpertAvatar(name: expert.expertName, photoUrl: expert.photoUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    expert.expertName,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: ZitlasTokens.textPrimary,
                    ),
                  ),
                  if (spec != null)
                    Text(spec, style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary)),
                  if (areas.isNotEmpty)
                    Text(
                      areas,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: ZitlasTokens.textMuted),
                    ),
                  const SizedBox(height: 3),
                  Text(
                    formatProgramPrice(expert.pricePaise),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ZitlasTokens.primary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: Key('programExpertSelect_${expert.expertId}'),
              onPressed: onSelect,
              style: FilledButton.styleFrom(
                backgroundColor: ZitlasTokens.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('Select'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The expert's photo when their profile has one, otherwise their initials.
class _ExpertAvatar extends StatelessWidget {
  const _ExpertAvatar({required this.name, this.photoUrl});

  final String name;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    final url = photoUrl;
    return CircleAvatar(
      radius: 22,
      backgroundColor: ZitlasTokens.primary.withValues(alpha: 0.12),
      foregroundImage: url == null ? null : NetworkImage(url),
      onForegroundImageError: url == null ? null : (_, _) {},
      child: Text(
        initials.isEmpty ? '?' : initials,
        style: const TextStyle(fontWeight: FontWeight.w800, color: ZitlasTokens.primary),
      ),
    );
  }
}
