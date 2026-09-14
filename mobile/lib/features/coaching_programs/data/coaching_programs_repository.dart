import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../payments/data/wallet_repository.dart'
    show InsufficientWalletBalance, WalletFrozenException;
import '../models/program_offer.dart';

/// Why a program request (or its payment) was refused, in words an athlete
/// can act on. [code] is the backend's machine-readable reason
/// (`program_unavailable`, `program_request_exists`, `not_accepted`, ...).
class ProgramRequestException implements Exception {
  const ProgramRequestException(this.message, {this.code, this.statusCode});

  final String message;
  final String? code;
  final int? statusCode;

  @override
  String toString() => message;
}

class ProgramRequestResult {
  const ProgramRequestResult({required this.request, required this.alreadyRequested});

  final ProgramRequest request;

  /// True when the same program was already requested and still waiting —
  /// the server returned that request instead of creating another.
  final bool alreadyRequested;
}

/// A payment the server CONFIRMED: the program is paid and running.
class ProgramPaymentResult {
  const ProgramPaymentResult({
    required this.request,
    required this.alreadyPaid,
    this.balance,
  });

  /// The program as the server now has it — active, paid, with its dates.
  final ProgramRequest request;

  /// A repeat of a payment already made (a double tap, a retry after a
  /// timeout). Nothing was charged a second time.
  final bool alreadyPaid;

  /// The SERVER's wallet balance after the payment.
  final double? balance;
}

/// Personal Coaching Programs — prices, requests and payment through the
/// backend (`/api/coaching-programs`, routes/coaching_programs.py).
///
/// Sends only WHICH expert and WHICH program, and to pay, only WHICH
/// request. The price, duration, status and payment state are decided
/// server-side, and the wallet is debited only there. Nothing here opens
/// Razorpay: a short wallet comes back as [InsufficientWalletBalance] and the
/// screen offers the existing Add Funds flow.
class CoachingProgramsRepository {
  CoachingProgramsRepository({required ApiClient apiClient}) : _api = apiClient;

  /// The app's instance: signed-in Firebase user's ID token on every call.
  /// The token is read lazily, per request — never at construction.
  factory CoachingProgramsRepository.live() {
    final api = ApiClient();
    api.authTokenProvider = () async => FirebaseAuth.instance.currentUser?.getIdToken();
    return CoachingProgramsRepository(apiClient: api);
  }

  final ApiClient _api;

  Future<ProgramOffer> fetchOffer(String expertId) async {
    final res = await _api.get('/api/coaching-programs/experts/${Uri.encodeComponent(expertId)}');
    if (res is! Map) {
      throw const ApiException(message: 'Malformed programs response');
    }
    return ProgramOffer.fromJson(res);
  }

  Future<ProgramRequestResult> requestProgram({
    required String expertId,
    required String programId,
  }) async {
    final dynamic res;
    try {
      res = await _api.post(
        '/api/coaching-programs/requests',
        body: {'expertId': expertId, 'programId': programId},
      );
    } on ApiException catch (e) {
      throw ProgramRequestException(messageFor(e), code: codeOf(e), statusCode: e.statusCode);
    }
    final request = res is Map ? ProgramRequest.fromJson(res['request']) : null;
    if (request == null) {
      throw const ProgramRequestException('Could not send your request. Please try again.');
    }
    return ProgramRequestResult(
      request: request,
      alreadyRequested: res is Map && res['alreadyRequested'] == true,
    );
  }

  /// `POST /api/coaching-programs/requests/{id}/pay` — pays an ACCEPTED
  /// program in full from the athlete's wallet and starts it.
  ///
  /// No body: the server charges the request's own price snapshot. Repeating
  /// the call (a double tap, a retry after a timeout) returns the same paid
  /// program and charges nothing more.
  ///
  /// Throws [InsufficientWalletBalance] (402) when the wallet does not cover
  /// the price — nothing was charged, and the program stays payable after
  /// Add Funds. Throws [WalletFrozenException] while the Wallet is frozen.
  Future<ProgramPaymentResult> payForProgram(String requestId) async {
    final dynamic res;
    try {
      res = await _api.post('/api/coaching-programs/requests/${Uri.encodeComponent(requestId)}/pay');
    } on ApiException catch (e) {
      if (e.statusCode == 402) {
        final detail = e.body is Map ? (e.body as Map)['detail'] : null;
        final required = detail is Map ? detail['required'] : null;
        final available = detail is Map ? detail['available'] : null;
        throw InsufficientWalletBalance(
          requiredPaise: required is num ? required.toInt() : 0,
          availablePaise: available is num ? available.toInt() : 0,
        );
      }
      if (e.statusCode == 503 && codeOf(e) == 'wallet_frozen') {
        throw const WalletFrozenException();
      }
      throw ProgramRequestException(messageFor(e), code: codeOf(e), statusCode: e.statusCode);
    }
    final request = res is Map ? ProgramRequest.fromJson(res['request']) : null;
    if (request == null || !request.isPaid) {
      throw const ProgramRequestException(
        "We couldn't confirm your payment. Please refresh before trying again.",
      );
    }
    final balance = res is Map ? res['balance'] : null;
    return ProgramPaymentResult(
      request: request,
      alreadyPaid: res is Map && res['already'] == true,
      balance: balance is num ? balance.toDouble() : null,
    );
  }

  static String? codeOf(ApiException e) {
    final body = e.body;
    if (body is! Map) return null;
    final detail = body['detail'];
    if (detail is String) return detail;
    if (detail is Map && detail['error'] is String) return detail['error'] as String;
    return null;
  }

  static String messageFor(ApiException e) {
    switch (codeOf(e)) {
      case 'program_unavailable':
        return "This program isn't available from this expert right now.";
      case 'program_request_exists':
        return 'You already have a program request with this expert.';
      case 'open_request_exists':
        return 'You already have a coaching request waiting for a response.';
      case 'active_coaching_exists':
        return 'You already have an active personal coach.';
      case 'expert_not_found':
        return "This coach isn't available right now. Please choose another.";
      case 'cannot_request_self':
        return "You can't request your own program.";
      case 'invalid_program':
        return 'That program is no longer offered.';
      case 'not_accepted':
        return "Your expert hasn't accepted this program yet.";
      case 'not_payable':
        return 'This program can no longer be paid for.';
      case 'request_invalid':
      case 'payment_already_recorded':
        return "This program can't be paid right now. Please contact support — nothing was charged.";
      case 'program_payments_disabled':
        return 'Program payments are not available right now. Nothing was charged.';
    }
    if (e.statusCode == 401 || e.statusCode == 403) {
      return 'Please sign in again to continue.';
    }
    if (e.isNetworkError || e.isServerError) {
      return "Couldn't reach ZITLAS. Please try again in a moment.";
    }
    return 'Could not send your request. Please try again.';
  }
}
