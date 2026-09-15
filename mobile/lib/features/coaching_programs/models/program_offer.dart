/// What an expert offers on the Programs screen, and where the athlete's own
/// request with them stands — as the server reports it.
///
/// Every number here comes from `GET /api/coaching-programs/experts/{id}`.
/// Nothing is priced in the app: a program the server does not price is not
/// offered by that expert (and the screen says so), never ₹0.
library;

enum ProgramRequestStatus { pendingExpertAcceptance, accepted, declined, active, completed, unknown }

ProgramRequestStatus _statusFrom(Object? raw) => switch (raw) {
      'pending_expert_acceptance' => ProgramRequestStatus.pendingExpertAcceptance,
      'accepted' => ProgramRequestStatus.accepted,
      'declined' => ProgramRequestStatus.declined,
      'active' => ProgramRequestStatus.active,
      // Set by the expiry sweep once a paid program's end date has passed.
      'completed' => ProgramRequestStatus.completed,
      _ => ProgramRequestStatus.unknown,
    };

/// Only a positive whole number of paise is a price. `0`, negatives, `499.0`
/// and `"499"` are all "no price".
int? _positivePaise(Object? raw) => (raw is int && raw > 0) ? raw : null;

DateTime? _date(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;

/// The athlete's request for one program with one expert — and, once paid,
/// the program itself.
class ProgramRequest {
  const ProgramRequest({
    required this.requestId,
    required this.expertId,
    required this.programId,
    required this.status,
    this.expertName,
    this.durationDays,
    this.pricePaise,
    this.paymentStatus,
    this.expertAccepted = false,
    this.requestedAt,
    this.paidAt,
    this.startedAt,
    this.endsAt,
    this.amountPaidPaise,
  });

  final String requestId;
  final String expertId;
  final String? expertName;
  final String programId;
  final int? durationDays;

  /// The price snapshotted by the server when the request was made — the
  /// amount Pay & Start charges. Never a number the app chose.
  final int? pricePaise;
  final ProgramRequestStatus status;

  /// `unpaid` · `payment_required` · `paid`
  final String? paymentStatus;
  final bool expertAccepted;
  final DateTime? requestedAt;
  final DateTime? paidAt;
  final DateTime? startedAt;
  final DateTime? endsAt;
  final int? amountPaidPaise;

  /// Still waiting on something — the expert (pending) or payment (accepted).
  bool get isOpen =>
      status == ProgramRequestStatus.pendingExpertAcceptance ||
      status == ProgramRequestStatus.accepted;

  /// Accepted by the expert and waiting for the athlete to pay.
  bool get awaitingPayment =>
      status == ProgramRequestStatus.accepted && paymentStatus != 'paid';

  bool get isPaid => paymentStatus == 'paid';

  /// A paid program that has not reached its end date.
  bool isRunning(DateTime now) =>
      status == ProgramRequestStatus.active && (endsAt == null || endsAt!.isAfter(now));

  static ProgramRequest? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['requestId'];
    final expertId = json['expertId'];
    final programId = json['programId'];
    if (id is! String || id.isEmpty || expertId is! String || programId is! String) {
      return null;
    }
    final days = json['durationDays'];
    return ProgramRequest(
      requestId: id,
      expertId: expertId,
      expertName: json['expertName'] is String ? json['expertName'] as String : null,
      programId: programId,
      durationDays: days is int && days > 0 ? days : null,
      pricePaise: _positivePaise(json['pricePaise']),
      status: _statusFrom(json['status']),
      paymentStatus: json['paymentStatus'] is String ? json['paymentStatus'] as String : null,
      expertAccepted: json['expertAccepted'] == true,
      requestedAt: _date(json['requestedAt']),
      paidAt: _date(json['paidAt']),
      startedAt: _date(json['startedAt']),
      endsAt: _date(json['endsAt']),
      amountPaidPaise: _positivePaise(json['amountPaidPaise']),
    );
  }
}

/// One expert's program prices plus the athlete's current request with them.
class ProgramOffer {
  const ProgramOffer({
    required this.expertId,
    required this.expertName,
    required this.prices,
    this.expertAvailable = true,
    this.request,
  });

  final String expertId;
  final String expertName;

  /// False only when the server says this expert takes no program requests
  /// (`expertAvailable: false`). An older server that doesn't send it means
  /// available — an unpriced program is then "not offered by this expert".
  final bool expertAvailable;

  /// programId → price in paise, for the programs actually offered.
  final Map<String, int> prices;

  /// The open request with this expert if there is one, else the latest.
  final ProgramRequest? request;

  int? priceFor(String programId) => prices[programId];

  factory ProgramOffer.fromJson(Map<dynamic, dynamic> json) {
    final prices = <String, int>{};
    final programs = json['programs'];
    if (programs is List) {
      for (final p in programs) {
        if (p is! Map || p['available'] != true) continue;
        final id = p['programId'];
        final price = _positivePaise(p['pricePaise']);
        if (id is String && price != null) prices[id] = price;
      }
    }
    return ProgramOffer(
      expertId: json['expertId'] is String ? json['expertId'] as String : '',
      expertName: json['expertName'] is String ? json['expertName'] as String : 'your expert',
      prices: Map.unmodifiable(prices),
      expertAvailable: json['expertAvailable'] != false,
      request: ProgramRequest.fromJson(json['request']),
    );
  }

  ProgramOffer withRequest(ProgramRequest request) => ProgramOffer(
        expertId: expertId,
        expertName: expertName,
        prices: prices,
        expertAvailable: expertAvailable,
        request: request,
      );
}

/// One expert who offers a program, at their OWN server-side price — a row
/// in Get Started's "choose your expert" step
/// (`GET /api/coaching-programs/programs/{programId}/experts`).
class ProgramExpertOption {
  const ProgramExpertOption({
    required this.expertId,
    required this.expertName,
    required this.pricePaise,
    this.specialization,
    this.photoUrl,
    this.expertise = const [],
  });

  final String expertId;
  final String expertName;

  /// The price the server quotes today. The request re-reads the expert's
  /// price when it is made, so this number is never charged by itself.
  final int pricePaise;
  final String? specialization;

  /// The expert's profile photo (an http(s) URL), when they have one.
  final String? photoUrl;

  /// A few areas the expert works in, from their own profile.
  final List<String> expertise;

  static ProgramExpertOption? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['expertId'];
    final price = _positivePaise(json['pricePaise']);
    if (id is! String || id.isEmpty || price == null) return null;
    final name = json['expertName'];
    final spec = json['specialization'];
    final photo = json['photoUrl'];
    final areas = json['expertise'];
    return ProgramExpertOption(
      expertId: id,
      expertName: name is String && name.trim().isNotEmpty ? name.trim() : 'Expert',
      pricePaise: price,
      specialization: spec is String && spec.trim().isNotEmpty ? spec.trim() : null,
      photoUrl: photo is String && (photo.startsWith('https://') || photo.startsWith('http://'))
          ? photo
          : null,
      expertise: areas is List
          ? [for (final a in areas) if (a is String && a.trim().isNotEmpty) a.trim()]
          : const [],
    );
  }
}

/// 499900 → `₹4,999` · 49950 → `₹499.50` (Indian grouping, like the wallet).
String formatProgramPrice(int paise) {
  final rupees = paise ~/ 100;
  final cents = paise % 100;
  final digits = rupees.toString();
  String grouped;
  if (digits.length <= 3) {
    grouped = digits;
  } else {
    final last3 = digits.substring(digits.length - 3);
    var head = digits.substring(0, digits.length - 3);
    final groups = <String>[];
    while (head.length > 2) {
      groups.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) groups.insert(0, head);
    grouped = '${groups.join(',')},$last3';
  }
  return cents == 0 ? '₹$grouped' : '₹$grouped.${cents.toString().padLeft(2, '0')}';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// `23 Sep 2026`, in the device's local time.
String formatProgramDate(DateTime when) {
  final d = when.toLocal();
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}
