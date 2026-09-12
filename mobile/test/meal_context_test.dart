import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/coaching/data/coaching_plan_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_checkin_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_photo_uploader.dart';
import 'package:zitlas_mobile/features/coaching/models/meal_checkin.dart';
import 'package:zitlas_mobile/features/coaching/models/meal_context.dart';
import 'package:zitlas_mobile/features/coaching/presentation/screens/meal_review_screen.dart';
import 'package:zitlas_mobile/features/diet/data/diet_repository.dart';
import 'package:zitlas_mobile/features/diet/diet_controller.dart';
import 'package:zitlas_mobile/features/diet/presentation/widgets/meal_confirm_sheet.dart';
import 'package:zitlas_mobile/features/diet/presentation/widgets/meal_snap_button.dart';
import 'package:zitlas_mobile/features/expert_dashboard/models/expert_models.dart';
import 'package:zitlas_mobile/features/experts/data/experts_repository.dart';

/// "What is this meal?" — the athlete's answer, from photo to coach.
///
///     photo → What is this meal? → Chicken + Rice → Send to Coach
///       → meal_checkins/{id}.mealContext → the coach's card, beside the photo
///
/// THE RULES THESE PROTECT
///   * nothing is uploaded until Send to Coach — backing out sends nothing;
///   * the answer rides the EXISTING check-in: same uploader, same Storage
///     prefix, same document, same coach notifications — one field added;
///   * a failed upload keeps the sheet and the answer, so a retry is one tap;
///   * check-ins sent before this step keep rendering exactly as they did;
///   * the payload matches the website's case for case
///     (tests/js/meal-context.test.mjs runs the same cases).

// ─── fakes ─────────────────────────────────────────────────────────────────

class _FakeAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _storageUrl = 'https://firebasestorage.googleapis.com/v0/b/zitlas-b8677.firebasestorage.app'
    '/o/meal_checkins%2Fathlete-1%2Flunch.jpg?alt=media&token=t';

/// The real [MealPhotoUploader] with only its two network edges stubbed.
class _FakeUploader extends MealPhotoUploader {
  _FakeUploader() : super(auth: _FakeAuth());

  int prepared = 0;
  int uploads = 0;
  String? failWith;
  String? pathPrefix;
  bool? requireDurable;

  @override
  Future<PreparedMealPhoto> prepare(File file) async {
    prepared++;
    return (bytes: utf8.encode('jpeg'), contentType: 'image/jpeg', fileName: 'meal.jpg');
  }

  @override
  Future<String> uploadPrepared(
    PreparedMealPhoto photo, {
    String pathPrefix = 'meal_checkins',
    bool requireDurable = false,
  }) async {
    uploads++;
    this.pathPrefix = pathPrefix;
    this.requireDurable = requireDurable;
    final failure = failWith;
    if (failure != null) throw Exception(failure);
    return _storageUrl;
  }
}

/// The backend: the AI nutrition estimate and the coach-push trigger.
class _Backend {
  final requests = <http.Request>[];

  late final ApiClient api = ApiClient(
    baseUrl: 'https://api.test',
    httpClient: MockClient((request) async {
      requests.add(request);
      final body = request.url.path == '/api/meal/estimate-nutrition'
          ? {
              'calories': 540,
              'protein': 32,
              'carbs': 61,
              'fat': 18,
              'food_recognition': ['chicken curry', 'steamed rice'],
              'confidence_score': 0.72,
            }
          : {'ok': true};
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    }),
  )..authTokenProvider = () async => 'athlete-id-token';
}

CoachingRelationship _coaching({String status = 'active'}) => CoachingRelationship(
      id: 'athlete-1',
      status: status,
      planType: 'diet',
      coachId: 'coach-9',
      athleteId: 'athlete-1',
    );

/// The SAME cases, value for value, as tests/js/meal-context.test.mjs — a meal
/// described on either client is stored identically.
const _shared = <(List<String>, bool, String, Map<String, Object?>)>[
  (
    ['Chicken', 'Rice'],
    false,
    '',
    {'items': ['Chicken', 'Rice'], 'custom': null, 'description': 'Chicken + Rice', 'source': 'user'},
  ),
  (
    [],
    true,
    '  Chicken curry with steamed rice  ',
    {
      'items': <String>[],
      'custom': 'Chicken curry with steamed rice',
      'description': 'Chicken curry with steamed rice',
      'source': 'user',
    },
  ),
  (
    ['Rice', 'rice', 'Dal', 'Rice'],
    true,
    'RICE',
    {'items': ['Rice', 'Dal'], 'custom': 'RICE', 'description': 'Rice + Dal', 'source': 'user'},
  ),
  (
    ['Paneer'],
    true,
    "Mom's  Sunday thali — 2 rotis 🍛",
    {
      'items': ['Paneer'],
      'custom': "Mom's  Sunday thali — 2 rotis 🍛",
      'description': "Paneer + Mom's  Sunday thali — 2 rotis 🍛",
      'source': 'user',
    },
  ),
  (
    ['Dal'],
    false,
    'Poha',
    {'items': ['Dal'], 'custom': null, 'description': 'Dal', 'source': 'user'},
  ),
];

// ─── the confirmation step, driven with scripted answers ───────────────────

class _Flow {
  _Flow({required this.sources, required this.picks, List<String?>? results})
      : results = results ?? [];

  final List<ImageSource?> sources; // camera/gallery sheet: null = dismissed
  final List<File?> picks; // the picker: null = cancelled
  final List<String?> results; // each send: null = delivered, text = its failure
  final pickedFrom = <ImageSource>[];
  final sent = <(String, MealContext)>[]; // (photo path, answer)
  Completer<String?>? hold;
  bool? outcome;
}

void _tallView(WidgetTester tester) {
  // The sheet holds eleven chips, a field and two buttons; give it room so
  // every tap lands on what a phone would show.
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _open(WidgetTester tester, _Flow f) async {
  _tallView(tester);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              f.outcome = await runMealPhotoFlow(
                context,
                mealName: 'Lunch',
                chooseSource: () async => f.sources.removeAt(0),
                pickPhoto: (source) async {
                  f.pickedFrom.add(source);
                  return f.picks.removeAt(0);
                },
                send: (photo, answer) {
                  f.sent.add((photo.path, answer));
                  final hold = f.hold;
                  if (hold != null) return hold.future;
                  return Future.value(f.results.isEmpty ? null : f.results.removeAt(0));
                },
              );
            },
            child: const Text('Snap'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Snap'));
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _chip(WidgetTester tester, String item) => _tapKey(tester, 'mealChip_$item');

Future<void> _sendToCoach(WidgetTester tester) => _tapKey(tester, 'mealSendToCoach');

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('mealCustomField')), text);
  await tester.pump();
}

String _photoShown(WidgetTester tester) =>
    (tester.widget<Image>(find.byKey(const Key('mealConfirmPhoto'))).image as FileImage).file.path;

String _typed(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('mealCustomField'))).controller!.text;

Finder _selected(String item) => find.byKey(Key('mealSelected_$item'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the answer, as both clients store it', () {
    for (final (selected, other, typed, stored) in _shared) {
      test('→ ${stored['description']}', () {
        final built = buildMealContext(selected: selected, otherSelected: other, customText: typed);
        expect(built.error, isNull);
        expect(built.context!.toMap(), stored);
      });
    }

    test('nothing chosen is refused — never guessed', () {
      expect(
        buildMealContext(selected: [], otherSelected: false, customText: '').error,
        'Pick what this meal is, or type it in.',
      );
    });

    test('"Other" with only spaces is refused', () {
      expect(
        buildMealContext(selected: ['Dal'], otherSelected: true, customText: '   ').error,
        'Enter a meal name, or unselect Other.',
      );
    });

    test('the custom name is capped — and the cap itself is allowed', () {
      final atCap = 'a' * kMealCustomMaxLength;
      expect(
        buildMealContext(selected: [], otherSelected: true, customText: atCap).context!.custom,
        atCap,
      );
      expect(
        buildMealContext(selected: [], otherSelected: true, customText: '${atCap}b').error,
        'Keep the meal name within 200 characters.',
      );
    });

    test('the quick picks are exactly the ten asked for, in order', () {
      expect(kMealQuickItems, [
        'Biryani', 'Chicken', 'Paratha', 'Rice', 'Dal', //
        'Eggs', 'Salad', 'Roti', 'Vegetables', 'Paneer',
      ]);
    });
  });

  group('check-ins sent before this step', () {
    Map<String, dynamic> doc([Map<String, dynamic> extra = const {}]) => {
          'checkinId': 'MCI_1',
          'athleteId': 'athlete-1',
          'coachId': 'coach-9',
          'mealType': 'lunch',
          'mealName': 'Lunch',
          'status': 'pending',
          'timestamp': '2026-09-11T13:00:00.000Z',
          ...extra,
        };

    test('have no mealContext, and are written back without one', () {
      final old = MealCheckin.fromMap(doc())!;
      expect(old.mealContext, isNull);
      expect(old.toMap().containsKey('mealContext'), isFalse);
    });

    test('a malformed value is ignored rather than breaking the check-in', () {
      for (final junk in <Object?>[
        'Chicken',
        42,
        <String, dynamic>{},
        {'items': 'Rice', 'custom': 7},
        {'items': [' ', 3]},
      ]) {
        final c = MealCheckin.fromMap(doc({'mealContext': junk}));
        expect(c, isNotNull, reason: '$junk');
        expect(c!.mealContext, isNull, reason: '$junk');
      }
    });

    test('an answer written by the website reads back exactly as written', () {
      final c = MealCheckin.fromMap(doc({
        'mealContext': {
          'items': ['Dal'],
          'custom': 'jeera rice',
          'description': 'Dal + jeera rice',
          'source': 'user',
        },
      }))!;
      expect(c.mealContext!.items, ['Dal']);
      expect(c.mealContext!.custom, 'jeera rice');
      expect(c.mealContext!.description, 'Dal + jeera rice');
      expect(MealContext.fromMap(c.mealContext!.toMap())!.toMap(), c.mealContext!.toMap());
    });
  });

  group('"What is this meal?"', () {
    testWidgets('nothing is sent until Send to Coach — the step shows the photo, the question '
        'and every chip', (tester) async {
      final f = _Flow(sources: [ImageSource.gallery], picks: [File('lunch.jpg')]);
      await _open(tester, f);

      expect(f.pickedFrom, [ImageSource.gallery]);
      expect(find.text('What is this meal?'), findsOneWidget);
      expect(find.text("Tell your coach what you're eating."), findsOneWidget);
      expect(_photoShown(tester), 'lunch.jpg');
      for (final item in [...kMealQuickItems, 'Other']) {
        expect(find.byKey(Key('mealChip_$item')), findsOneWidget, reason: item);
      }
      expect(find.text('Change Photo'), findsOneWidget);
      expect(find.text('Send to Coach'), findsOneWidget);
      expect(f.sent, isEmpty, reason: 'taking the photo must not send it');
    });

    testWidgets('several foods at once, never twice, each removable', (tester) async {
      final f = _Flow(sources: [ImageSource.camera], picks: [File('dinner.jpg')]);
      await _open(tester, f);
      expect(f.pickedFrom, [ImageSource.camera]);

      await _chip(tester, 'Chicken');
      await _chip(tester, 'Rice');
      await _chip(tester, 'Dal');
      expect(_selected('Chicken'), findsOneWidget);
      expect(_selected('Rice'), findsOneWidget);
      expect(_selected('Dal'), findsOneWidget);

      // Tapping a picked food again unpicks it — it is never listed twice.
      await _chip(tester, 'Rice');
      expect(_selected('Rice'), findsNothing);

      // The × on a selected food removes it.
      final removeDal = find.byTooltip('Remove Dal');
      await tester.ensureVisible(removeDal);
      await tester.tap(removeDal);
      await tester.pumpAndSettle();
      expect(_selected('Dal'), findsNothing);

      await _chip(tester, 'Rice');
      await _sendToCoach(tester);

      final (photo, answer) = f.sent.single;
      expect(photo, 'dinner.jpg');
      expect(answer.items, ['Chicken', 'Rice']);
      expect(answer.description, 'Chicken + Rice');
      expect(f.outcome, isTrue);
      expect(find.text('What is this meal?'), findsNothing);
    });

    testWidgets('"Other" opens "Enter meal name" — a name alone is enough, sent as typed',
        (tester) async {
      final f = _Flow(sources: [ImageSource.gallery], picks: [File('lunch.jpg')]);
      await _open(tester, f);

      expect(find.byKey(const Key('mealCustomField')), findsNothing);
      await _chip(tester, 'Other');
      expect(find.byKey(const Key('mealCustomField')), findsOneWidget);
      expect(find.text('Enter meal name'), findsOneWidget);

      await _type(tester, '  Chicken curry with steamed rice  ');
      await _sendToCoach(tester);

      final answer = f.sent.single.$2;
      expect(answer.items, isEmpty, reason: 'no quick pick is required');
      expect(answer.custom, 'Chicken curry with steamed rice');
      expect(answer.description, 'Chicken curry with steamed rice');
    });

    testWidgets('with nothing chosen, or "Other" left blank, nothing is sent', (tester) async {
      final f = _Flow(sources: [ImageSource.gallery], picks: [File('lunch.jpg')]);
      await _open(tester, f);

      await _sendToCoach(tester);
      expect(find.text('Pick what this meal is, or type it in.'), findsOneWidget);

      await _chip(tester, 'Other');
      await _type(tester, '   ');
      await _sendToCoach(tester);
      expect(find.text('Enter a meal name, or unselect Other.'), findsOneWidget);

      expect(f.sent, isEmpty);
      expect(find.text('What is this meal?'), findsOneWidget);
    });

    testWidgets('the name field stops at the cap', (tester) async {
      final f = _Flow(sources: [ImageSource.gallery], picks: [File('lunch.jpg')]);
      await _open(tester, f);
      await _chip(tester, 'Other');

      final field = tester.widget<TextField>(find.byKey(const Key('mealCustomField')));
      expect(field.maxLength, kMealCustomMaxLength);
      await _type(tester, 'x' * (kMealCustomMaxLength + 50));
      await _sendToCoach(tester);
      expect(f.sent.single.$2.custom, 'x' * kMealCustomMaxLength);
    });

    testWidgets('tapping outside the sheet sends nothing', (tester) async {
      final f = _Flow(sources: [ImageSource.gallery], picks: [File('lunch.jpg')]);
      await _open(tester, f);
      await _chip(tester, 'Chicken');

      await tester.tapAt(const Offset(20, 20)); // the modal barrier
      await tester.pumpAndSettle();

      expect(find.text('What is this meal?'), findsNothing);
      expect(f.sent, isEmpty);
      expect(f.outcome, isFalse);
    });

    testWidgets('dismissing the camera/gallery choice, or the picker, opens and sends nothing',
        (tester) async {
      for (final f in [
        _Flow(sources: [null], picks: []),
        _Flow(sources: [ImageSource.gallery], picks: [null]),
      ]) {
        await _open(tester, f);
        expect(find.text('What is this meal?'), findsNothing);
        expect(f.sent, isEmpty);
        expect(f.outcome, isFalse);
      }
    });

    testWidgets('Change Photo re-opens the camera/gallery and keeps the answer; cancelling it '
        'keeps the photo', (tester) async {
      final f = _Flow(
        sources: [ImageSource.gallery, ImageSource.camera, ImageSource.camera],
        picks: [File('first.jpg'), null, File('second.jpg')],
      );
      await _open(tester, f);
      await _chip(tester, 'Chicken');
      await _chip(tester, 'Other');
      await _type(tester, 'with raita');

      // Picker cancelled: same photo, same answer.
      await _tapKey(tester, 'mealChangePhoto');
      expect(_photoShown(tester), 'first.jpg');
      expect(_selected('Chicken'), findsOneWidget);
      expect(_typed(tester), 'with raita');

      // A new photo: the answer is still there.
      await _tapKey(tester, 'mealChangePhoto');
      expect(_photoShown(tester), 'second.jpg');
      expect(_selected('Chicken'), findsOneWidget);
      expect(_typed(tester), 'with raita');

      await _sendToCoach(tester);
      expect(f.pickedFrom, [ImageSource.gallery, ImageSource.camera, ImageSource.camera]);
      final (photo, answer) = f.sent.single;
      expect(photo, 'second.jpg');
      expect(answer.toMap(), {
        'items': ['Chicken'],
        'custom': 'with raita',
        'description': 'Chicken + with raita',
        'source': 'user',
      });
    });

    testWidgets('a failed send keeps the sheet and everything chosen — retry sends the same answer',
        (tester) async {
      final f = _Flow(
        sources: [ImageSource.gallery],
        picks: [File('lunch.jpg')],
        results: ['Upload failed — check your connection.', null],
      );
      await _open(tester, f);
      await _chip(tester, 'Paneer');
      await _chip(tester, 'Roti');
      await _chip(tester, 'Other');
      await _type(tester, 'extra ghee');

      await _sendToCoach(tester);
      expect(find.text('Upload failed — check your connection.'), findsOneWidget);
      expect(find.text('What is this meal?'), findsOneWidget, reason: 'the sheet stays open');
      expect(_selected('Paneer'), findsOneWidget);
      expect(_selected('Roti'), findsOneWidget);
      expect(_typed(tester), 'extra ghee');
      expect(f.outcome, isNull, reason: 'the flow is still waiting on the athlete');

      await _sendToCoach(tester);
      expect(f.outcome, isTrue);
      expect(f.sent, hasLength(2));
      expect(f.sent[1].$2.toMap(), f.sent[0].$2.toMap(), reason: 'the retry carries the same answer');
      expect(f.sent[1].$2.description, 'Paneer + Roti + extra ghee');
    });

    testWidgets('while sending, the button reads "Sending…" and a second tap sends nothing more',
        (tester) async {
      final f = _Flow(sources: [ImageSource.gallery], picks: [File('lunch.jpg')])
        ..hold = Completer<String?>();
      await _open(tester, f);
      await _chip(tester, 'Eggs');

      await tester.tap(find.byKey(const Key('mealSendToCoach')));
      await tester.pump();
      expect(find.text('Sending…'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mealSendToCoach')), warnIfMissed: false);
      await tester.pump();
      expect(f.sent, hasLength(1));

      f.hold!.complete(null);
      await tester.pumpAndSettle();
      expect(f.outcome, isTrue);
    });
  });

  group('the EXISTING check-in path carries the answer', () {
    late FakeFirebaseFirestore db;
    late _FakeUploader uploader;
    late _Backend backend;

    setUp(() {
      db = FakeFirebaseFirestore();
      uploader = _FakeUploader();
      backend = _Backend();
    });

    Future<MealCheckin> submit({MealContext? answer}) => MealCheckinRepository(
          firestore: db,
          uploader: uploader,
          api: backend.api,
          auth: _FakeAuth(),
        ).submit(
          photo: File('lunch.jpg'),
          athleteId: 'athlete-1',
          athleteName: 'Asha',
          coachId: 'coach-9',
          mealName: 'Lunch',
          day: 'Friday',
          mealContext: answer,
        );

    Future<List<Map<String, dynamic>>> checkins() async =>
        [for (final d in (await db.collection('meal_checkins').get()).docs) d.data()];

    test('mealContext is one more field on the SAME meal_checkins document', () async {
      final saved = await submit(answer: const MealContext(items: ['Chicken', 'Rice']));
      final doc = (await checkins()).single;

      expect(doc['mealContext'], {
        'items': ['Chicken', 'Rice'],
        'custom': null,
        'description': 'Chicken + Rice',
        'source': 'user',
      });

      // Everything that was there before is still there, unchanged.
      expect(doc['checkinId'], saved.checkinId);
      expect(doc['athleteId'], 'athlete-1');
      expect(doc['coachId'], 'coach-9');
      expect(doc['mealName'], 'Lunch');
      expect(doc['mealType'], 'lunch');
      expect(doc['status'], 'pending');
      expect(doc['imageUrl'], _storageUrl);
      expect(doc['estimatedCalories'], 540);
      expect(doc['foodRecognition'], ['chicken curry', 'steamed rice'],
          reason: 'the AI estimate stays its own field — it never rewrites what the athlete said');

      // The same uploader, Storage prefix and durability rule as before.
      expect(uploader.uploads, 1);
      expect(uploader.pathPrefix, 'meal_checkins');
      expect(uploader.requireDurable, isTrue);

      // The same coach notifications: the in-app record, and the push trigger,
      // which names only the check-in — the backend derives the recipient.
      expect((await db.collection('coaching_notifications').get()).docs, hasLength(1));
      final push = backend.requests.singleWhere((r) => r.url.path == '/api/notifications/meal-checkin');
      expect(jsonDecode(push.body), {'checkinId': saved.checkinId});
    });

    test('a check-in without an answer keeps its old shape', () async {
      await submit();
      expect((await checkins()).single.containsKey('mealContext'), isFalse);
    });

    test('a failed upload writes nothing — a retry cannot leave a half check-in', () async {
      uploader.failWith = 'Upload failed — check your connection.';
      await expectLater(
        submit(answer: const MealContext(items: ['Dal'])),
        throwsA(isA<Exception>()),
      );
      expect(await checkins(), isEmpty);
      expect(
        backend.requests.map((r) => r.url.path),
        isNot(contains('/api/notifications/meal-checkin')),
      );
    });
  });

  group('Snap Meal, end to end — the EXISTING controller, repository and uploader', () {
    late FakeFirebaseFirestore db;
    late _FakeUploader uploader;
    late DietController diet;

    Future<void> openSnapMeal(WidgetTester tester) async {
      _tallView(tester);
      SharedPreferences.setMockInitialValues({});
      db = FakeFirebaseFirestore();
      uploader = _FakeUploader();
      diet = DietController(
        uid: 'athlete-1',
        repository: DietRepository(firestore: db),
        coachingPlans: CoachingPlanRepository(firestore: db),
        experts: ExpertsRepository(firestore: db, auth: _FakeAuth()),
        mealCheckins: MealCheckinRepository(
          firestore: db,
          uploader: uploader,
          api: _Backend().api,
          auth: _FakeAuth(),
        ),
      );
      // The constructor's first (empty) snapshots land asynchronously and
      // would overwrite a relationship assigned before they arrive.
      await tester.pump();
      diet.coachRelationship = _coaching();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: diet,
            builder: (_, _) => MealSnapRow(
              controller: diet,
              mealName: 'Lunch',
              athleteName: 'Asha',
              pickPhoto: (_) async => File('lunch.jpg'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Snap Meal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose from gallery'));
      await tester.pumpAndSettle();
    }

    Future<List<Map<String, dynamic>>> checkins() async =>
        [for (final d in (await db.collection('meal_checkins').get()).docs) d.data()];

    testWidgets('Chicken + Rice → upload fails → retry: ONE check-in, carrying the answer',
        (tester) async {
      await openSnapMeal(tester);
      expect(find.text('What is this meal?'), findsOneWidget);
      expect(uploader.prepared, 0, reason: 'nothing is uploaded before Send to Coach');

      await _chip(tester, 'Chicken');
      await _chip(tester, 'Rice');
      uploader.failWith = 'Upload failed — check your connection.';
      await _sendToCoach(tester);

      expect(find.text('Upload failed — check your connection.'), findsOneWidget);
      expect(_selected('Chicken'), findsOneWidget);
      expect(_selected('Rice'), findsOneWidget);
      expect(await checkins(), isEmpty);

      uploader.failWith = null;
      await _sendToCoach(tester);

      expect(find.text('What is this meal?'), findsNothing);
      expect(find.text('📷 Sent to your coach for review.'), findsOneWidget);
      final doc = (await checkins()).single;
      expect(doc['mealContext'], {
        'items': ['Chicken', 'Rice'],
        'custom': null,
        'description': 'Chicken + Rice',
        'source': 'user',
      });
      expect(doc['coachId'], 'coach-9');
      expect(doc['mealName'], 'Lunch');
      expect(doc['imageUrl'], _storageUrl);
      diet.dispose();
    });

    testWidgets('going back after the photo uploads nothing and writes nothing', (tester) async {
      await openSnapMeal(tester);
      await _chip(tester, 'Chicken');

      // What the system back button does: pop the top route.
      await Navigator.of(tester.element(find.text('What is this meal?'))).maybePop();
      await tester.pumpAndSettle();

      expect(find.text('What is this meal?'), findsNothing);
      expect(uploader.prepared, 0);
      expect(uploader.uploads, 0);
      expect(await checkins(), isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Snap Meal'), findsOneWidget, reason: 'the athlete can simply try again');
      diet.dispose();
    });
  });

  group('what the coach sees', () {
    Future<void> pumpQueue(WidgetTester tester, List<Map<String, dynamic>> checkins) async {
      final db = FakeFirebaseFirestore();
      for (var i = 0; i < checkins.length; i++) {
        await db.collection('meal_checkins').doc('MCI_$i').set({
          'checkinId': 'MCI_$i',
          'athleteId': 'athlete-1',
          'athleteName': 'Alice',
          'coachId': 'coach-9',
          'day': 'Friday',
          'mealType': 'lunch',
          'mealName': 'Lunch',
          'status': 'pending',
          'timestamp': '2026-09-11T13:0$i:00.000Z',
          ...checkins[i],
        });
      }
      // Each card carries a ~190px photo area and the queue is a lazy list.
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: MealReviewScreen(
          coachId: 'coach-9',
          coachName: 'pratik',
          repository: MealCheckinRepository(firestore: db, uploader: MealPhotoUploader()),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets("the athlete's answer is on the card, beside the photo", (tester) async {
      await pumpQueue(tester, [
        {'mealContext': const MealContext(items: ['Chicken', 'Rice']).toMap()},
      ]);
      expect(find.text('📷 “Chicken + Rice”'), findsOneWidget);
    });

    testWidgets('a name typed on the website shows exactly as typed — plain text, never markup',
        (tester) async {
      await pumpQueue(tester, [
        {
          'mealContext': {
            'items': <String>[],
            'custom': '<b>Poha</b> & "chai"',
            'description': '<b>Poha</b> & "chai"',
            'source': 'user',
          },
        },
      ]);
      expect(find.text('📷 “<b>Poha</b> & "chai"”'), findsOneWidget);
    });

    testWidgets('check-ins without mealContext render exactly as before', (tester) async {
      await pumpQueue(tester, [
        {}, // every check-in sent until now
        {'mealContext': 'Chicken'}, // malformed: ignored, never a crash
        {'mealContext': {'items': 'Rice', 'custom': 7}},
      ]);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Lunch'), findsWidgets);
      expect(find.textContaining('📷 “'), findsNothing);
    });
  });
}
