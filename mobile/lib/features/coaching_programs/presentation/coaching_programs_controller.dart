import 'package:flutter/foundation.dart';

import '../../payments/data/wallet_repository.dart'
    show InsufficientWalletBalance, WalletFrozenException;
import '../coaching_programs.dart';
import '../data/coaching_programs_repository.dart';
import '../models/program_offer.dart';

enum ProgramsLoadState { loading, ready, failed }

enum ProgramPaymentState { idle, paying, insufficient }

/// What happened when the athlete acted — the screen shows [message] (an
/// empty message means the screen itself shows the result, e.g. the
/// insufficient-balance card).
class ProgramRequestOutcome {
  const ProgramRequestOutcome({required this.ok, required this.message});

  final bool ok;
  final String message;
}

/// The Programs screen's state: the selected expert's server-side prices,
/// the athlete's request with them, sending a request, and paying for an
/// accepted one from the ZITLAS Wallet.
///
/// Without an expert nothing is priced and no call is made — until the
/// athlete chooses one in Get Started's "choose your expert" step
/// ([expertsFor], then [selectExpert]).
class CoachingProgramsController extends ChangeNotifier {
  CoachingProgramsController({
    required String? expertId,
    this.repository,
    DateTime Function()? clock,
  })  : _expertId = expertId, // ignore: prefer_initializing_formals
        _clock = clock ?? DateTime.now;

  final CoachingProgramsRepository? repository;
  final DateTime Function() _clock;

  /// The expert whose prices are shown and whom Get Started asks — the one
  /// the screen opened from, or the one the athlete chose.
  String? _expertId;
  String? get expertId => _expertId;

  ProgramsLoadState _state = ProgramsLoadState.loading;
  ProgramOffer? _offer;
  String? _submitting;
  ProgramPaymentState _payment = ProgramPaymentState.idle;
  InsufficientWalletBalance? _shortfall;
  bool _disposed = false;

  ProgramsLoadState get state => _state;
  ProgramOffer? get offer => _offer;
  String? get submittingProgramId => _submitting;
  ProgramPaymentState get paymentState => _payment;
  bool get paying => _payment == ProgramPaymentState.paying;

  /// Set while the wallet does not cover the accepted program — the SERVER's
  /// required and available figures, for the insufficient-balance card.
  InsufficientWalletBalance? get shortfall => _shortfall;

  DateTime now() => _clock();

  /// The server's price for [programId], or null — "Currently unavailable".
  int? priceFor(String programId) =>
      _state == ProgramsLoadState.ready ? _offer?.priceFor(programId) : null;

  /// The athlete's request with this expert (open, or the most recent).
  ProgramRequest? get request => _offer?.request;

  /// A request still waiting on the expert or on payment, or a program
  /// still running — while there is one, no other program can be started
  /// with this expert.
  ProgramRequest? get openRequest {
    final r = request;
    if (r == null) return null;
    return (r.isOpen || r.isRunning(_clock())) ? r : null;
  }

  Future<void> load() async {
    final repo = repository;
    final id = expertId;
    if (repo == null || id == null || id.isEmpty) {
      _offer = null;
      _state = ProgramsLoadState.ready;
      _notify();
      return;
    }
    _state = ProgramsLoadState.loading;
    _notify();
    try {
      _offer = await repo.fetchOffer(id);
      _state = ProgramsLoadState.ready;
      if (!(_offer?.request?.awaitingPayment ?? false)) {
        _shortfall = null;
        _payment = ProgramPaymentState.idle;
      }
    } catch (e) {
      debugPrint('[COACHING PROGRAMS] could not load programs for $id: $e');
      _state = ProgramsLoadState.failed;
    }
    _notify();
  }

  /// Sends ONLY the expert and the program. The server decides the price.
  Future<ProgramRequestOutcome> requestProgram(String programId) async {
    final repo = repository;
    final id = expertId;
    if (repo == null || id == null || _submitting != null) {
      return const ProgramRequestOutcome(ok: false, message: kProgramUnavailable);
    }
    _submitting = programId;
    _notify();
    try {
      final result = await repo.requestProgram(expertId: id, programId: programId);
      _offer = _offer?.withRequest(result.request);
      return ProgramRequestOutcome(
        ok: true,
        message: result.alreadyRequested ? kProgramAlreadyRequested : kProgramRequestSent,
      );
    } on ProgramRequestException catch (e) {
      // The server knows something this screen does not (a price was
      // withdrawn, a request is already open) — reload the truth.
      if (e.code == 'program_unavailable' || e.code == 'program_request_exists') {
        _submitting = null;
        await load();
      }
      return ProgramRequestOutcome(ok: false, message: e.message);
    } catch (e) {
      debugPrint('[COACHING PROGRAMS] request failed: $e');
      return const ProgramRequestOutcome(
        ok: false,
        message: 'Could not send your request. Please try again.',
      );
    } finally {
      _submitting = null;
      _notify();
    }
  }

  /// PAY & START PROGRAM — the accepted request, paid in full from the
  /// wallet, at the price the SERVER recorded. The app sends only which
  /// request; a repeat (double tap, retry) is answered with the same paid
  /// program and never charged again.
  ///
  /// A short wallet sets [shortfall] and charges nothing; Razorpay is never
  /// opened from here — Add Funds is the athlete's explicit choice.
  Future<ProgramRequestOutcome> payAndStart() async {
    final repo = repository;
    final r = request;
    if (repo == null || r == null || !r.awaitingPayment || paying) {
      return const ProgramRequestOutcome(ok: false, message: '');
    }
    _payment = ProgramPaymentState.paying;
    _notify();
    try {
      final result = await repo.payForProgram(r.requestId);
      _offer = _offer?.withRequest(result.request);
      _shortfall = null;
      _payment = ProgramPaymentState.idle;
      return ProgramRequestOutcome(
        ok: true,
        message: result.alreadyPaid ? kProgramAlreadyPaid : kProgramStarted,
      );
    } on InsufficientWalletBalance catch (e) {
      _shortfall = e;
      _payment = ProgramPaymentState.insufficient;
      return const ProgramRequestOutcome(ok: false, message: '');
    } on WalletFrozenException catch (e) {
      _payment = ProgramPaymentState.idle;
      return ProgramRequestOutcome(ok: false, message: e.toString());
    } on ProgramRequestException catch (e) {
      _payment = ProgramPaymentState.idle;
      // Whatever the reason, the server's state is what the screen must show
      // next — e.g. already paid on another device, or no longer payable.
      await load();
      final unconfirmed = e.code == null && (e.statusCode == null || e.statusCode! >= 500);
      return ProgramRequestOutcome(
        ok: false,
        message: unconfirmed ? kProgramPaymentUnconfirmed : e.message,
      );
    } catch (e) {
      debugPrint('[COACHING PROGRAMS] payment failed: $e');
      _payment = ProgramPaymentState.idle;
      await load();
      return const ProgramRequestOutcome(ok: false, message: kProgramPaymentUnconfirmed);
    } finally {
      if (_payment == ProgramPaymentState.paying) _payment = ProgramPaymentState.idle;
      _notify();
    }
  }

  /// After a CONFIRMED top-up: re-read the server-written wallet and redo
  /// the shortfall. The program is deliberately NOT paid here — the athlete
  /// taps Pay & Start Program again. Returns true when the wallet now covers
  /// the price.
  Future<bool> onFundsAdded(Future<double> Function() availableRupees) async {
    final short = _shortfall;
    if (short == null) return true;
    try {
      final availablePaise = ((await availableRupees()) * 100).round();
      if (availablePaise >= short.requiredPaise) {
        _shortfall = null;
        _payment = ProgramPaymentState.idle;
      } else {
        _shortfall = InsufficientWalletBalance(
          requiredPaise: short.requiredPaise,
          availablePaise: availablePaise,
        );
      }
    } catch (e) {
      // Keep the card as it was; the next Pay tap asks the server anyway.
      debugPrint('[COACHING PROGRAMS] wallet refresh failed: $e');
    }
    _notify();
    return _shortfall == null;
  }

  /// The athlete chose an expert in Get Started's "choose your expert" step:
  /// show THEIR prices and their existing request, so a request already
  /// waiting is shown rather than duplicated. Nothing is sent here.
  Future<void> selectExpert(String expertId) async {
    final id = expertId.trim();
    if (id.isEmpty) return;
    if (id == _expertId && _state == ProgramsLoadState.ready && _offer != null) return;
    _expertId = id;
    _offer = null;
    _shortfall = null;
    _payment = ProgramPaymentState.idle;
    await load();
  }

  /// The approved experts who offer [programId], each at their own price.
  Future<List<ProgramExpertOption>> expertsFor(String programId) {
    final repo = repository;
    if (repo == null) {
      return Future.error(const ProgramRequestException(kProgramExpertsLoadFailed));
    }
    return repo.fetchProgramExperts(programId);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
