import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_checkin_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_photo_uploader.dart';
import 'package:zitlas_mobile/features/coaching/models/meal_checkin.dart';

/// MealCheckinRepository's backend calls carry the signed-in user's ID token.
///
/// THE BUG THIS PINS. The repository built a bare `ApiClient()` with no
/// `authTokenProvider`. Both push triggers it calls —
/// `/api/notifications/meal-checkin` (athlete → coach) and `/meal-review`
/// (coach → athlete) — verify the caller, so every one was rejected 401, and
/// the failure was swallowed as "best-effort, non-fatal". Production held
/// zero server-side `meal_review_pending` notifications as a result: a coach
/// was never pushed about a meal submitted from the app.
class _User implements User {
  _User(this._token);
  final String _token;

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => _token;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Auth implements FirebaseAuth {
  _Auth(this._user);
  final User? _user;

  @override
  User? get currentUser => _user;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// For the uploader, which is not under test here.
class _NoAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late List<http.Request> requests;

  ApiClient api() {
    requests = [];
    return ApiClient(
      httpClient: MockClient((r) async {
        requests.add(r);
        return http.Response('{"success": true}', 200,
            headers: {'content-type': 'application/json'});
      }),
      baseUrl: 'https://api.test',
    );
  }

  MealCheckinRepository repo(ApiClient client, {FirebaseAuth? auth}) =>
      MealCheckinRepository(
        firestore: FakeFirebaseFirestore(),
        uploader: MealPhotoUploader(auth: _NoAuth()),
        api: client,
        auth: auth,
      );

  const checkin = MealCheckin(
    checkinId: 'MCI_1',
    athleteId: 'athlete_1',
    coachId: 'coach_1',
    mealType: 'lunch',
    mealName: 'Lunch',
    status: 'pending',
  );

  test("the meal-review push trigger carries the reviewer's ID token", () async {
    final client = api();
    await repo(client, auth: _Auth(_User('COACH_ID_TOKEN'))).review(
      checkin: checkin,
      reaction: MealReaction.great,
      coachName: 'Coach Srujan',
    );

    final push = requests
        .where((r) => r.url.path == '/api/notifications/meal-review')
        .toList();
    expect(push, hasLength(1));
    expect(push.single.headers['Authorization'], 'Bearer COACH_ID_TOKEN',
        reason: 'without it the route answers 401 and the athlete is never pushed');
  });

  test('the meal-checkin push trigger is authenticated too', () async {
    final client = api();
    repo(client, auth: _Auth(_User('ATHLETE_ID_TOKEN')));

    await client.post('/api/notifications/meal-checkin',
        body: {'checkinId': 'MCI_1'});
    expect(requests.single.headers['Authorization'], 'Bearer ATHLETE_ID_TOKEN');
  });

  test('a token provider the caller already configured is kept', () async {
    final client = api()..authTokenProvider = () async => 'CALLER_TOKEN';
    repo(client, auth: _Auth(_User('OTHER_TOKEN')));
    expect(await client.authTokenProvider!(), 'CALLER_TOKEN');
  });

  test('with no Firebase app the provider yields null instead of throwing',
      () async {
    final client = api();
    repo(client); // no auth injected, and Firebase is not initialised in tests
    expect(await client.authTokenProvider!(), isNull);
  });
}
