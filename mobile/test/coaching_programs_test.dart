import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/coaching_programs/coaching_programs.dart';
import 'package:zitlas_mobile/features/coaching_programs/data/coaching_programs_repository.dart';
import 'package:zitlas_mobile/features/coaching_programs/presentation/coaching_programs_screen.dart';
import 'package:zitlas_mobile/features/coaching_webview/coaching_webview_screen.dart';
import 'package:zitlas_mobile/features/experts/data/expert_rating_repository.dart';
import 'package:zitlas_mobile/features/experts/data/experts_repository.dart';
import 'package:zitlas_mobile/features/experts/data/pending_rating_prompt.dart';
import 'package:zitlas_mobile/features/experts/models/expert_rating.dart';
import 'package:zitlas_mobile/features/experts/presentation/screens/experts_screen.dart';

/// Personal Coaching Programs — the screen and the ways into it (Phase 1),
/// kept green through Phase 2. Prices and requests themselves are covered by
/// coaching_programs_requests_test.dart.
///
///     Personal Coaching → Personal Coaching Programs → 10-Day / 1-Month / 3-Month
///
/// What these protect:
///   * every way into Personal Coaching lands on the Programs screen, never on
///     the old Diet / Training / Complete picker;
///   * the three programs, their copy and their EXISTING artwork render,
///     stacked vertically in a scrolling page;
///   * no price lives in the app, and the feature cannot reach payment, the
///     wallet or Firestore; without an expert nothing is priced or started;
///   * everything else in the coaching journey (Request Review, Chat, the
///     coach-profile WebView) behaves exactly as before.

class _FakeAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A backend that offers nothing — enough for the screen to open.
CoachingProgramsRepository _emptyProgramsRepo() => CoachingProgramsRepository(
      apiClient: ApiClient(
        baseUrl: 'https://api.test',
        httpClient: MockClient((_) async => http.Response(
              '{"expertId":"coach-1","expertName":"Asha Rao","programs":[],"request":null}',
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            )),
      ),
    );

/// Never asks for an expert rating — not what these tests are about.
class _NoRatingPrompt extends PendingRatingPrompt {
  _NoRatingPrompt() : super(repository: ExpertRatingRepository(auth: _FakeAuth()));

  @override
  Future<PendingExpertRating?> check() async => null;
}

String _assetOf(ImageProvider provider) {
  final inner = provider is ResizeImage ? provider.imageProvider : provider;
  return (inner as AssetImage).assetName;
}

/// Tall enough that the (lazy) list builds all three cards at once.
void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpPrograms(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: CoachingProgramsScreen()));
  await tester.pump();
}

const _oldPickerCopy = [
  'Diet Coaching',
  'Training Coaching',
  'Complete Coaching',
  'Complete Transformation',
  'Choose a monthly coaching plan.',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the three programs', () {
    test('exactly three, in the order the athlete sees them', () {
      expect(kCoachingPrograms.map((p) => p.id), ['10_day', '1_month', '3_month']);
      expect(
        kCoachingPrograms.map((p) => p.title),
        ['10-Day Program', '1-Month Program', '3-Month Program'],
      );
    });

    test('each uses its existing artwork, by its existing file name', () {
      expect(kCoachingPrograms.map((p) => p.imageAsset), [
        'assets/images/10 program.png',
        'assets/images/1 month program.png',
        'assets/images/3 month.png',
      ]);
      for (final p in kCoachingPrograms) {
        expect(File(p.imageAsset).existsSync(), isTrue, reason: p.imageAsset);
      }
    });

    test('every image is declared in pubspec.yaml and actually bundled', () async {
      final pubspec = File('pubspec.yaml').readAsStringSync().replaceAll('\r\n', '\n');
      for (final p in kCoachingPrograms) {
        expect(pubspec, contains('- ${p.imageAsset}\n'), reason: p.imageAsset);
        // The file names contain spaces — this proves Flutter bundles and
        // serves them under exactly these keys.
        final bytes = await rootBundle.load(p.imageAsset);
        expect(bytes.lengthInBytes, greaterThan(100000), reason: p.imageAsset);
      }
    });

    test('no price is hard-coded in the program catalog', () {
      for (final p in kCoachingPrograms) {
        final copy = [p.title, p.durationLabel, p.description, ...p.highlights].join(' ');
        expect(copy, isNot(contains('₹')), reason: p.id);
        expect(copy.toLowerCase(), isNot(contains('price')), reason: p.id);
        expect(copy, isNot(contains('/mo')), reason: p.id);
      }
    });

    test('the location carries the expert only when there is one', () {
      expect(coachingProgramsLocation(), '/coaching-programs');
      expect(coachingProgramsLocation(expertId: '  '), '/coaching-programs');
      expect(coachingProgramsLocation(expertId: 'coach-1'), '/coaching-programs?expertId=coach-1');
    });

    test('the coach-profile bridge message is read exactly', () {
      expect(isOpenProgramsBridgeMessage('open-programs:coach-9'), isTrue);
      expect(isOpenProgramsBridgeMessage('open-programs'), isTrue);
      expect(isOpenProgramsBridgeMessage('auth-ok:uid'), isFalse);
      expect(isOpenProgramsBridgeMessage('open-programs-x'), isFalse);
      expect(expertIdFromProgramsBridgeMessage('open-programs:coach-9'), 'coach-9');
      expect(expertIdFromProgramsBridgeMessage('open-programs:'), isNull);
      expect(expertIdFromProgramsBridgeMessage('open-programs'), isNull);
      expect(expertIdFromProgramsBridgeMessage('need-token'), isNull);
    });
  });

  group('the Programs screen', () {
    testWidgets('opens on Personal Coaching Programs, with the 10-Day Program first',
        (tester) async {
      await _pumpPrograms(tester);
      expect(find.text('Personal Coaching Programs'), findsOneWidget);
      expect(find.text('10-Day Program'), findsOneWidget);
      for (final old in _oldPickerCopy) {
        expect(find.textContaining(old), findsNothing, reason: old);
      }
    });

    testWidgets('the three programs are stacked one below another, full width', (tester) async {
      _tallView(tester);
      await _pumpPrograms(tester);

      final cards = [for (final p in kCoachingPrograms) find.byKey(Key('coachingProgram_${p.id}'))];
      for (final card in cards) {
        expect(card, findsOneWidget);
      }
      final rects = cards.map(tester.getRect).toList();
      expect(rects[0].bottom, lessThanOrEqualTo(rects[1].top));
      expect(rects[1].bottom, lessThanOrEqualTo(rects[2].top));
      expect(rects.map((r) => r.left).toSet(), hasLength(1), reason: 'never side by side');
      expect(rects.map((r) => r.width).toSet(), hasLength(1));
    });

    testWidgets('the page scrolls to reach the later programs', (tester) async {
      await _pumpPrograms(tester);
      final list = find.descendant(
        of: find.byKey(const Key('coachingProgramsList')),
        matching: find.byType(Scrollable),
      );

      expect(find.text('3-Month Program'), findsNothing, reason: 'below the fold at first');
      await tester.scrollUntilVisible(find.text('3-Month Program'), 400, scrollable: list);
      expect(find.text('3-Month Program'), findsOneWidget);
      expect(tester.state<ScrollableState>(list).position.pixels, greaterThan(0));
    });

    testWidgets('every program shows its description, its highlights and Get Started',
        (tester) async {
      _tallView(tester);
      await _pumpPrograms(tester);

      for (final p in kCoachingPrograms) {
        final card = find.byKey(Key('coachingProgram_${p.id}'));
        expect(find.descendant(of: card, matching: find.text(p.title)), findsOneWidget);
        expect(find.descendant(of: card, matching: find.text(p.description)), findsOneWidget);
        expect(find.descendant(of: card, matching: find.text(p.durationLabel)), findsOneWidget);
        for (final h in p.highlights) {
          expect(find.descendant(of: card, matching: find.text(h)), findsOneWidget, reason: '${p.id}: $h');
        }
        expect(find.byKey(Key('coachingProgramGetStarted_${p.id}')), findsOneWidget);
      }
    });

    testWidgets('each card shows its own artwork, uncropped', (tester) async {
      _tallView(tester);
      await _pumpPrograms(tester);

      for (final p in kCoachingPrograms) {
        final finder = find.byKey(Key('coachingProgramImage_${p.id}'));
        expect(_assetOf(tester.widget<Image>(finder).image), p.imageAsset);
        final size = tester.getSize(finder);
        expect(size.width / size.height, closeTo(1983 / 793, 0.01), reason: p.id);
      }
    });

    testWidgets('fits a small phone (320 × 640) without overflowing', (tester) async {
      tester.view.physicalSize = const Size(960, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await _pumpPrograms(tester);
      final list = find.descendant(
        of: find.byKey(const Key('coachingProgramsList')),
        matching: find.byType(Scrollable),
      );

      for (final p in kCoachingPrograms) {
        await tester.scrollUntilVisible(
          find.byKey(Key('coachingProgramGetStarted_${p.id}')),
          300,
          scrollable: list,
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('without an expert nothing is priced — and Get Started asks who to work with',
        (tester) async {
      _tallView(tester);
      final listed = <Uri>[];
      final router = GoRouter(
        initialLocation: kCoachingProgramsPath,
        routes: [
          coachingProgramsRoute(
            repository: CoachingProgramsRepository(
              apiClient: ApiClient(
                baseUrl: 'https://api.test',
                httpClient: MockClient((r) async {
                  listed.add(r.url);
                  return http.Response('{"programId":"10_day","experts":[]}', 200,
                      headers: {'content-type': 'application/json; charset=utf-8'});
                }),
              ),
            ),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pump();

      expect(find.text(kProgramChooseExpertToPrice), findsNWidgets(kCoachingPrograms.length));
      expect(find.text(kProgramUnavailable), findsNothing);
      expect(find.textContaining('₹'), findsNothing, reason: 'never ₹0, never a made-up price');
      expect(listed, isEmpty, reason: 'nothing is fetched until the athlete asks');
      for (final p in kCoachingPrograms) {
        final key = Key('coachingProgramGetStarted_${p.id}');
        expect(tester.widget<FilledButton>(find.byKey(key)).onPressed, isNotNull,
            reason: '${p.id}: Get Started is never a dead end');
      }

      await tester.tap(find.byKey(const Key('coachingProgramGetStarted_10_day')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('programExpertPicker')), findsOneWidget);
      expect(listed.single.path, '/api/coaching-programs/programs/10_day/experts');
      expect(find.text(kProgramNoExperts), findsOneWidget);
      expect(find.byType(CoachingProgramsScreen), findsOneWidget);
    });

    test('the Programs feature pays only through its own endpoint and the existing Add Funds', () {
      final files = Directory('lib/features/coaching_programs')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(files.length, greaterThanOrEqualTo(5));
      // Phase 3 legitimately uses the EXISTING wallet pieces (Add Funds flow,
      // wallet repository, insufficient-balance card). What must never appear:
      // Razorpay itself, the payment/Premium endpoints, Firestore, or the
      // old coaching escrow.
      const forbidden = [
        'cloud_firestore',
        'razorpay',
        'Razorpay',
        '/api/payment',
        'purchasePremium',
        'createOrder',
        'verifyTopUp',
        '/membership',
        '/api/coaching/',
        'personal_coach_requests',
        'experts_repository',
        'submitCoachingRequest',
      ];
      for (final file in files) {
        // Code only — a comment explaining what is NOT touched is fine.
        final code = file
            .readAsLinesSync()
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        for (final f in forbidden) {
          expect(code.contains(f), isFalse, reason: '${file.path} must not reference $f');
        }
      }
      final screen = File('lib/features/coaching_programs/presentation/coaching_programs_screen.dart')
          .readAsStringSync();
      expect(screen, contains('runAddFunds('), reason: 'Add Funds is the existing flow');
      final repo = File('lib/features/coaching_programs/data/coaching_programs_repository.dart')
          .readAsStringSync();
      expect(repo, contains("/api/coaching-programs/requests/\${Uri.encodeComponent(requestId)}/pay"));
    });
  });

  group('Personal Coaching now opens the Programs screen', () {
    late FakeFirebaseFirestore db;
    late GoRouter router;

    Future<void> pumpExperts(WidgetTester tester) async {
      db = FakeFirebaseFirestore();
      await db.collection('experts').doc('coach-1').set({
        'name': 'Asha Rao',
        'specialization': 'Sports Nutritionist',
        'approved': true,
        'verified': true,
      });
      router = GoRouter(
        initialLocation: '/experts',
        routes: [
          GoRoute(
            path: '/experts',
            builder: (_, _) => ExpertsScreen(
              repository: ExpertsRepository(firestore: db, auth: _FakeAuth()),
              ratingPrompt: _NoRatingPrompt(),
            ),
          ),
          // Stand-in for the coach-profile WebView (a platform view).
          GoRoute(
            path: '/coach-profile/:id',
            builder: (_, state) => Scaffold(body: Text('coach-profile ${state.uri}')),
          ),
          coachingProgramsRoute(repository: _emptyProgramsRepo()),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
    }

    testWidgets('Experts: Personal Coach opens Programs — not the Diet / Training / Complete picker',
        (tester) async {
      await pumpExperts(tester);
      final button = find.widgetWithText(OutlinedButton, 'Personal Coach');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();

      final screen = find.byType(CoachingProgramsScreen);
      expect(screen, findsOneWidget);
      expect(tester.widget<CoachingProgramsScreen>(screen).expertId, 'coach-1',
          reason: 'the expert travels with the athlete — their prices, their request');
      expect(find.text('Personal Coaching Programs'), findsOneWidget);
      expect(find.textContaining('coach-profile'), findsNothing,
          reason: 'Personal Coach no longer opens the coach-profile WebView');
      for (final old in _oldPickerCopy) {
        expect(find.textContaining(old), findsNothing, reason: old);
      }
    });

    testWidgets('Experts: Request Review still opens the coach profile, as before', (tester) async {
      await pumpExperts(tester);
      final button = find.widgetWithText(OutlinedButton, 'Request Review');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(find.text('coach-profile /coach-profile/coach-1?action=verify'), findsOneWidget);
      expect(find.byType(CoachingProgramsScreen), findsNothing);
    });

    test('inside a coach profile, the app advertises the native Programs screen', () {
      final plain = CoachingWebViewScreen.coachProfile(expertId: 'coach-1');
      expect(plain.relativePath, contains('expertId=coach-1'));
      expect(plain.relativePath, contains('&webview=1&nativePrograms=1'));
      final chat = CoachingWebViewScreen.coachProfile(expertId: 'coach-1', action: 'ask');
      expect(chat.relativePath, endsWith('&action=ask'), reason: 'other deep links unchanged');
    });

    test('the native expert profile opens Programs too', () {
      final src = File('lib/features/experts/presentation/screens/expert_profile_screen.dart')
          .readAsStringSync();
      expect(src, isNot(contains('showPersonalCoachingSheet')));
      expect('coachingProgramsLocation(expertId: controller.expertId)'.allMatches(src),
          hasLength(2), reason: 'the Personal Coach button and the action=coach deep link');
    });

    test('the old picker stays in the tree for later phases, but nothing opens it', () {
      const sheet = 'lib/features/experts/presentation/widgets/personal_coaching_sheet.dart';
      expect(File(sheet).existsSync(), isTrue);
      final callers = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !f.path.replaceAll(r'\', '/').endsWith(sheet.substring(4)))
          .where((f) => f.readAsStringSync().contains('showPersonalCoachingSheet('))
          .map((f) => f.path)
          .toList();
      expect(callers, isEmpty);
    });
  });
}
