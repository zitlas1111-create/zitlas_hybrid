/// One Personal Coaching program as the athlete sees it on the Programs
/// screen.
///
/// Copy and artwork only — deliberately NO price. Prices are the selected
/// expert's own and come from the server (Phase 2, see
/// `data/coaching_programs_repository.dart`); nothing here can price,
/// request or pay for a program.
class CoachingProgram {
  const CoachingProgram({
    required this.id,
    required this.title,
    required this.durationLabel,
    required this.description,
    required this.highlights,
    required this.imageAsset,
  });

  /// `10_day` | `1_month` | `3_month` — the same ids the backend prices
  /// (backend/services/coaching_programs.py).
  final String id;

  final String title;

  /// How long the program runs — a length, never a price.
  final String durationLabel;

  final String description;

  final List<String> highlights;

  /// Existing artwork in `assets/images/`, used exactly as supplied.
  final String imageAsset;
}

/// The three programs, in the order they are shown.
const kCoachingPrograms = <CoachingProgram>[
  CoachingProgram(
    id: '10_day',
    title: '10-Day Program',
    durationLabel: '10 days',
    description: 'Kick-start your transformation with focused expert guidance for 10 days.',
    highlights: [
      'Expert creates or customizes your diet plan',
      'Expert reviews and rates your meal photos',
      'Expert can adjust your diet when needed',
      'Regular diet review during the program',
      'Detailed Personal Coaching Report at the end',
    ],
    imageAsset: 'assets/images/10 program.png',
  ),
  CoachingProgram(
    id: '1_month',
    title: '1-Month Program',
    durationLabel: '30 days',
    description: 'Build consistent habits with expert guidance throughout your 30-day journey.',
    highlights: [
      'Personalized diet guidance',
      'Meal photo review by your expert',
      'Diet adjustments when needed',
      'Regular diet review',
      'Progress guidance',
      'Personal Coaching Report at completion',
    ],
    imageAsset: 'assets/images/1 month program.png',
  ),
  CoachingProgram(
    id: '3_month',
    title: '3-Month Program',
    durationLabel: '90 days',
    description:
        'Build lasting habits and make meaningful progress with longer-term expert guidance.',
    highlights: [
      'Personalized nutrition guidance',
      'Meal photo review',
      'Expert diet adjustments',
      'Regular plan reviews',
      'Progress guidance',
      'Personal Coaching Report at completion',
    ],
    imageAsset: 'assets/images/3 month.png',
  ),
];

/// Shown instead of a price when the chosen expert has not priced this
/// program (the server's `unavailableReason: not_priced`). Never "₹0", never
/// "free" — and never a stand-in for a failed load.
const kProgramNotOffered = "Your expert hasn't set a price for this program yet.";

/// The chosen expert takes no program requests at all
/// (`unavailableReason: expert_unavailable`).
const kProgramExpertUnavailable = "Your expert isn't taking program requests right now.";

/// The expert's prices could not be loaded — an error, not "not offered".
const kProgramPriceLoadFailed = "Couldn't load the price.";

/// Shown instead of a price before an expert is chosen — each expert sets
/// their own price, so there is no honest number to show yet.
const kProgramChooseExpertToPrice = 'Choose an expert to see their price';

/// A separate button under Get Started when the chosen expert doesn't offer
/// that program (or declined it). Experts are switched only by tapping it.
const kProgramChooseAnotherExpert = 'Choose Another Expert';

/// Get Started's "choose your expert" step.
const kProgramPickExpertTitle = 'Choose your expert';
const kProgramNoExperts = 'No expert offers this program right now. Please check back soon.';
const kProgramExpertsLoadFailed = "Couldn't load experts for this program. Please try again.";
const kProgramExpertLoadFailed = "Couldn't load this expert's prices. Please try again.";

const kProgramRequestSent =
    "Request sent to your expert. You won't be charged unless they accept and you pay.";
const kProgramAlreadyRequested = "You've already requested this program.";
const kProgramOtherRequestOpen = 'You already have a program request with this expert.';
const kProgramOtherRunning = 'You already have a program running with this expert.';

/// The payment's answer never arrived. Safe to retry: a request is charged
/// at most once, whatever happens to the connection.
const kProgramPaymentUnconfirmed =
    "We couldn't confirm your payment. Tap Pay & Start Program again — "
    "you won't be charged twice.";

/// Where the athlete's request stands. An accepted request is paid for from
/// the ZITLAS Wallet (Pay & Start Program) — at the price the server recorded.
const kProgramPendingTitle = 'Pending expert acceptance';
const kProgramPendingBody = 'Your request has been sent. Your expert will accept or decline it.';
const kProgramAcceptedTitle = 'Your expert accepted the program';
const kProgramAcceptedBody = 'Pay from your ZITLAS Wallet to start your program.';
const kProgramPayLabel = 'Pay & Start Program';
const kProgramActiveTitle = 'Program active';
const kProgramEndedTitle = 'Program ended';
const kProgramCompletedTitle = 'Program completed';
const kProgramStatusUnknownTitle = 'Status unavailable';
const kProgramStatusUnknownBody = "We couldn't read this request's status. Please refresh.";
const kProgramStarted = 'Payment successful — your program has started.';
const kProgramAlreadyPaid = 'This program is already paid for.';

/// A short wallet: the existing insufficient-balance card, in program words.
const kProgramShortfallMessage =
    'Programs are paid in full from your ZITLAS Wallet. Add funds to continue — '
    'nothing has been charged.';
const kProgramFundsAddedReady = 'Funds added. Tap Pay & Start Program to pay from your wallet.';
const kProgramFundsAddedShort =
    'Funds added, but your wallet is still short — add a little more to continue.';
const kProgramDeclinedTitle = 'Expert declined';
const kProgramDeclinedBody = 'Your expert declined this request. You can send a new one.';

/// Where Personal Coaching now starts.
const kCoachingProgramsPath = '/coaching-programs';

/// The Programs screen's location. [expertId] is the expert whose Personal
/// Coach button was tapped: the screen shows THEIR prices, and Get Started
/// sends the request to them.
String coachingProgramsLocation({String? expertId}) {
  final id = expertId?.trim();
  if (id == null || id.isEmpty) return kCoachingProgramsPath;
  return Uri(path: kCoachingProgramsPath, queryParameters: {'expertId': id}).toString();
}

/// The message a coach's profile (the website, inside the app's WebView)
/// sends when its Personal Coach button is tapped: `open-programs:<expertId>`
/// — see `_cpHandOffToNativePrograms` in cprofile.js.
const kOpenProgramsBridgeMessage = 'open-programs';

bool isOpenProgramsBridgeMessage(String message) =>
    message == kOpenProgramsBridgeMessage ||
    message.startsWith('$kOpenProgramsBridgeMessage:');

/// The expert id carried by an `open-programs:<expertId>` message, or null.
String? expertIdFromProgramsBridgeMessage(String message) {
  if (!isOpenProgramsBridgeMessage(message)) return null;
  final id = message.substring(kOpenProgramsBridgeMessage.length).replaceFirst(':', '').trim();
  return id.isEmpty ? null : id;
}
