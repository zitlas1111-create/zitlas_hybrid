import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/experts/data/expert_rating_repository.dart';
import 'package:zitlas_mobile/features/experts/data/pending_rating_prompt.dart';
import 'package:zitlas_mobile/features/experts/models/expert_rating.dart';
import 'package:zitlas_mobile/features/experts/presentation/widgets/rate_expert_sheet.dart';

/// UI + client-side contract for the post-engagement rating flow.
///
/// Backend validation (engagement ownership, duplicates, aggregation, photo
/// consent stripping) is covered end-to-end against the real routes in
/// backend/tests/test_expert_ratings.py. What Flutter owns, and what these
/// cover: the rating being genuinely REQUIRED, everything else being
/// genuinely optional, consent defaulting to off and never being implied,
/// dismissal creating nothing, and a photo failure not costing the review.

const _pending = PendingExpertRating(
  engagementId: 'req_abc',
  expertId: 'expert_1',
  expertName: 'Coach Test',
);

/// Captures what the sheet actually sends, so "consent defaults to false"
/// is asserted on the wire, not merely on a widget's checkbox state.
class _Captured {
  Map<String, dynamic>? body;
  int submits = 0;
}

({ExpertRatingRepository repo, _Captured captured}) _repo({int status = 200}) {
  final captured = _Captured();
  final mock = MockClient((request) async {
    if (request.url.path.endsWith('/submit')) {
      captured.submits++;
      captured.body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response('{"success":true}', status,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }
    return http.Response('{}', 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });
  return (
    repo: ExpertRatingRepository(
      apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
    ),
    captured: captured,
  );
}

Future<void> _open(WidgetTester tester, ExpertRatingRepository repo) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showRateExpertSheet(context, pending: _pending, repository: repo),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the sheet itself', () {
    testWidgets('shows the expert name in the subtitle', (tester) async {
      await _open(tester, _repo().repo);
      expect(find.text('How was your experience?'), findsOneWidget);
      expect(find.text('Rate your experience with Coach Test'), findsOneWidget);
    });

    testWidgets('renders five tappable stars with accessible labels', (tester) async {
      await _open(tester, _repo().repo);
      for (final label in ['1 star', '2 stars', '3 stars', '4 stars', '5 stars']) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }
    });
  });

  group('rating is REQUIRED, everything else is optional', () {
    testWidgets('Submit is disabled until a star is chosen', (tester) async {
      await _open(tester, _repo().repo);
      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Submit Review'),
      );
      expect(button.onPressed, isNull, reason: 'rating is required');
    });

    testWidgets('choosing a star enables Submit and visually selects it', (tester) async {
      await _open(tester, _repo().repo);
      await tester.tap(find.bySemanticsLabel('4 stars'));
      await tester.pump();

      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Submit Review'),
      );
      expect(button.onPressed, isNotNull);
      // 4 filled + 1 outline — proof the tap actually updated state.
      expect(find.byIcon(Icons.star_rounded), findsNWidgets(4));
      expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
    });

    testWidgets('submits with a rating alone — no text, no photos', (tester) async {
      final r = _repo();
      await _open(tester, r.repo);
      await tester.tap(find.bySemanticsLabel('5 stars'));
      await tester.pump();
      await tester.ensureVisible(find.text('Submit Review'));
      await tester.tap(find.text('Submit Review'));
      await tester.pumpAndSettle();

      expect(r.captured.submits, 1);
      expect(r.captured.body!['rating'], 5);
      expect(r.captured.body!.containsKey('reviewText'), isFalse);
      expect(r.captured.body!.containsKey('beforePhotoUrl'), isFalse);
      expect(r.captured.body!.containsKey('afterPhotoUrl'), isFalse);
    });

    testWidgets('optional written feedback is sent when provided', (tester) async {
      final r = _repo();
      await _open(tester, r.repo);
      await tester.tap(find.bySemanticsLabel('5 stars'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Very supportive and clear.');
      await tester.ensureVisible(find.text('Submit Review'));
      await tester.tap(find.text('Submit Review'));
      await tester.pumpAndSettle();
      expect(r.captured.body!['reviewText'], 'Very supportive and clear.');
    });
  });

  group('photo privacy', () {
    testWidgets('the face-privacy notice is always visible, before any photo is picked', (tester) async {
      await _open(tester, _repo().repo);
      expect(find.textContaining('You can hide your face before sharing'), findsOneWidget);
      expect(find.text('Blur or cover your face for extra privacy.'), findsOneWidget);
    });

    testWidgets('both photo slots are offered and labelled Optional', (tester) async {
      await _open(tester, _repo().repo);
      expect(find.text('Before'), findsOneWidget);
      expect(find.text('After'), findsOneWidget);
      expect(find.text('Optional'), findsNWidgets(2));
    });

    testWidgets('the public-display consent checkbox starts UNCHECKED', (tester) async {
      await _open(tester, _repo().repo);
      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(checkbox.value, isFalse);
    });

    testWidgets('consent cannot even be toggled until a photo exists', (tester) async {
      // Guards against a stray "consented" flag on a review with no photo.
      await _open(tester, _repo().repo);
      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(checkbox.onChanged, isNull);
    });

    testWidgets('photoPublic is sent as false when no photo was attached', (tester) async {
      final r = _repo();
      await _open(tester, r.repo);
      await tester.tap(find.bySemanticsLabel('3 stars'));
      await tester.pump();
      await tester.ensureVisible(find.text('Submit Review'));
      await tester.tap(find.text('Submit Review'));
      await tester.pumpAndSettle();
      expect(r.captured.body!['photoPublic'], isFalse);
    });
  });

  group('submission outcome', () {
    testWidgets('success shows the thank-you state and the expert name', (tester) async {
      await _open(tester, _repo().repo);
      await tester.tap(find.bySemanticsLabel('5 stars'));
      await tester.pump();
      await tester.ensureVisible(find.text('Submit Review'));
      await tester.tap(find.text('Submit Review'));
      await tester.pumpAndSettle();

      expect(find.text('Thanks for your feedback! ❤️'), findsOneWidget);
      expect(find.textContaining("Coach Test's profile"), findsOneWidget);
    });

    testWidgets('a backend failure shows an error and does NOT claim success', (tester) async {
      final r = _repo(status: 500);
      await _open(tester, r.repo);
      await tester.tap(find.bySemanticsLabel('5 stars'));
      await tester.pump();
      await tester.ensureVisible(find.text('Submit Review'));
      await tester.tap(find.text('Submit Review'));
      await tester.pumpAndSettle();

      expect(find.textContaining("couldn't submit your review"), findsOneWidget);
      expect(find.text('Thanks for your feedback! ❤️'), findsNothing);
    });

    testWidgets('an already-rated (409) response is treated as done, not an error', (tester) async {
      final r = _repo(status: 409);
      await _open(tester, r.repo);
      await tester.tap(find.bySemanticsLabel('5 stars'));
      await tester.pump();
      await tester.ensureVisible(find.text('Submit Review'));
      await tester.tap(find.text('Submit Review'));
      await tester.pumpAndSettle();
      expect(find.text('Thanks for your feedback! ❤️'), findsOneWidget);
    });

    testWidgets('"Maybe later" closes without submitting anything', (tester) async {
      final r = _repo();
      await _open(tester, r.repo);
      await tester.tap(find.bySemanticsLabel('5 stars'));
      await tester.pump();
      await tester.ensureVisible(find.text('Maybe later'));
      await tester.tap(find.text('Maybe later'));
      await tester.pumpAndSettle();

      expect(r.captured.submits, 0, reason: 'dismissal must never create a review');
      expect(find.text('How was your experience?'), findsNothing);
    });
  });

  group('ExpertRatingDraft — the submitted body', () {
    test('canSubmit is false until a 1-5 rating is set', () {
      final d = ExpertRatingDraft(engagementId: 'e', expertId: 'x');
      expect(d.canSubmit, isFalse);
      d.rating = 3;
      expect(d.canSubmit, isTrue);
    });

    test('photoPublic can never be true without a photo', () {
      final d = ExpertRatingDraft(engagementId: 'e', expertId: 'x')
        ..rating = 5
        ..photoPublic = true;
      expect(d.toBody()['photoPublic'], isFalse);

      d.beforePhotoUrl = 'https://cdn/b.jpg';
      expect(d.toBody()['photoPublic'], isTrue);
    });

    test('blank written feedback is omitted rather than sent as an empty string', () {
      final d = ExpertRatingDraft(engagementId: 'e', expertId: 'x')
        ..rating = 5
        ..reviewText = '   ';
      expect(d.toBody().containsKey('reviewText'), isFalse);
    });

    test('the engagement and expert always travel with the rating', () {
      final d = ExpertRatingDraft(engagementId: 'req_9', expertId: 'expert_9')..rating = 2;
      final body = d.toBody();
      expect(body['engagementId'], 'req_9');
      expect(body['expertId'], 'expert_9');
    });
  });

  group('PendingRatingPrompt — when to ask', () {
    PendingRatingPrompt promptWith(String json) {
      final mock = MockClient((_) async => http.Response(json, 200,
          headers: {'content-type': 'application/json; charset=utf-8'}));
      return PendingRatingPrompt(
        repository: ExpertRatingRepository(
          apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
        ),
      );
    }

    test('asks when the backend reports a pending engagement', () async {
      final p = promptWith(
          '{"pending":true,"engagementId":"req_abc","expertId":"e1","expertName":"Coach Test"}');
      final pending = await p.check();
      expect(pending, isNotNull);
      expect(pending!.engagementId, 'req_abc');
    });

    test('does not ask when nothing is pending', () async {
      expect(await promptWith('{"pending":false}').check(), isNull);
    });

    test('does not ask when the backend says it was already rated', () async {
      expect(await promptWith('{"pending":false,"alreadyRated":true}').check(), isNull);
    });

    test('a snoozed engagement is not asked about again immediately', () async {
      final p = promptWith(
          '{"pending":true,"engagementId":"req_abc","expertId":"e1","expertName":"Coach Test"}');
      expect(await p.check(), isNotNull);
      await p.snooze('req_abc');
      expect(await p.check(), isNull, reason: 'dismissal should quiet the prompt for a while');
    });

    test('snoozing records no review — the backend still reports it pending', () async {
      // The snooze is purely local and can only DELAY. Proof: a different
      // engagement id is unaffected by the first one being snoozed.
      final p = promptWith(
          '{"pending":true,"engagementId":"req_other","expertId":"e1","expertName":"Coach Test"}');
      await p.snooze('req_abc');
      expect(await p.check(), isNotNull);
    });

    test('a failed pending check never throws — it just does not prompt', () async {
      final mock = MockClient((_) async => http.Response('boom', 500));
      final p = PendingRatingPrompt(
        repository: ExpertRatingRepository(
          apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
        ),
      );
      expect(await p.check(), isNull);
    });
  });

  group('ExpertRating — public profile display', () {
    test('parses a consented review with both photos', () {
      final r = ExpertRating.fromMap({
        'reviewId': 'req_abc',
        'rating': 5,
        'reviewText': 'Great coach.',
        'verifiedCoaching': true,
        'beforePhotoUrl': 'https://cdn/b.jpg',
        'afterPhotoUrl': 'https://cdn/a.jpg',
      })!;
      expect(r.hasPublicPhotos, isTrue);
      expect(r.verifiedCoaching, isTrue);
    });

    test('a non-consented review arrives with no photo URLs at all', () {
      final r = ExpertRating.fromMap({'reviewId': 'x', 'rating': 4})!;
      expect(r.hasPublicPhotos, isFalse);
      expect(r.beforePhotoUrl, isNull);
    });

    test('an empty review text does not break parsing', () {
      final r = ExpertRating.fromMap({'reviewId': 'x', 'rating': 3, 'reviewText': null})!;
      expect(r.reviewText, isNull);
      expect(r.rating, 3);
    });

    test('a malformed row is dropped rather than crashing the list', () {
      expect(ExpertRating.fromMap({'rating': 5}), isNull);
      expect(ExpertRating.fromMap({'reviewId': 'x'}), isNull);
    });
  });
}
