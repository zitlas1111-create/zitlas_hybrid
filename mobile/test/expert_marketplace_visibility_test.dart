import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/experts/data/experts_repository.dart';
import 'package:zitlas_mobile/features/experts/models/expert_listing.dart';

/// The production Expert Marketplace lists EVERY document in `experts`.
///
/// Signup writes `experts/{uid}` with `approved: false` and tells the
/// applicant "Your account is created — your application is under review"
/// (login.js:337), and `POST /api/admin/experts/approve` flips the flag. So
/// the approval contract already exists on the WRITE side; the read side
/// simply never checks it, which is how an unapproved test account appears
/// publicly alongside real experts.
///
/// STATUS: the gate is BUILT and TESTED here but NOT wired into
/// `fetchExperts()` yet — see that method's doc comment. Enabling it before
/// confirming the live experts carry `approved: true` would empty the
/// marketplace rather than clean it.
///
/// The gate is deliberately `approved != false`, never `approved == true`:
/// a profile created before the field existed carries no `approved` key, and
/// hiding those would delist established real experts — the one outcome that
/// would be worse than the bug.

class _FakeAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late FakeFirebaseFirestore db;
  late ExpertsRepository repo;

  setUp(() {
    db = FakeFirebaseFirestore();
    repo = ExpertsRepository(firestore: db, auth: _FakeAuth());
  });

  Future<void> expert(String id, {required String name, Object? approved}) {
    return db.collection('experts').doc(id).set({
      'uid': id,
      'name': name,
      'role': 'expert',
      'rating': 5,
      'reviews': 0,
      if (approved != null) 'approved': approved,
    });
  }

  group('the model decides visibility from the three real states', () {
    ExpertListing listing(Object? approved) => ExpertListing.fromMap('e1', {
          'name': 'X',
          if (approved != null) 'approved': approved,
        });

    test('approved: true is listed', () {
      expect(listing(true).listedInMarketplace, isTrue);
    });

    test('approved: false is HIDDEN — this is what signup writes', () {
      expect(listing(false).listedInMarketplace, isFalse);
    });

    test('a MISSING approved field is listed (legacy real experts)', () {
      // Fail-open by design. Excluding these would empty the marketplace of
      // every expert onboarded before the flag existed.
      expect(listing(null).listedInMarketplace, isTrue);
      expect(listing(null).approved, isNull);
    });

    test('a non-boolean approved value is treated as absent, not as false', () {
      // Never silently delist a real expert over a malformed field.
      for (final junk in ['false', 0, '', 'no']) {
        final l = listing(junk);
        expect(l.approved, isNull, reason: 'junk=$junk');
        expect(l.listedInMarketplace, isTrue, reason: 'junk=$junk');
      }
    });
  });

  group('the query is currently UNGATED — the gate is staged, not enabled', () {
    // These tests pin the CURRENT production behaviour on purpose, so the
    // change is loud when the gate is switched on. They are a tripwire, not
    // an endorsement: `fetchExperts()` still returns unapproved profiles.
    test('an unapproved test account IS still listed today', () async {
      await expert('test-uid', name: 'Test Email', approved: false);
      await expert('real-1', name: 'Dr. Real Expert', approved: true);

      final listed = await repo.fetchExperts();
      expect(listed.length, 2,
          reason: 'the gate is not wired in yet - see fetchExperts() doc comment');
      // ...but the model already knows it should not be:
      final test = listed.firstWhere((e) => e.name == 'Test Email');
      expect(test.listedInMarketplace, isFalse,
          reason: 'enabling `.where((e) => e.listedInMarketplace)` removes it');
    });

    test('real approved experts are listed', () async {
      await expert('r1', name: 'Coach A', approved: true);
      await expert('r2', name: 'Coach B', approved: true);
      expect((await repo.fetchExperts()).length, 2);
    });

    test('legacy experts with no approved field would survive the gate', () async {
      await expert('legacy', name: 'Established Expert');
      final listed = await repo.fetchExperts();
      expect(listed.single.listedInMarketplace, isTrue,
          reason: 'the gate must never delist an expert predating the field');
    });

    test('the gate would select exactly the visible ones', () async {
      await expert('t1', name: 'Test Email', approved: false);
      await expert('t2', name: 'demo tester', approved: false);
      await expert('r1', name: 'Real One', approved: true);
      await expert('r2', name: 'Legacy Real');

      final wouldShow = (await repo.fetchExperts())
          .where((e) => e.listedInMarketplace)
          .map((e) => e.name)
          .toSet();
      expect(wouldShow, {'Real One', 'Legacy Real'});
    });

    test('an empty collection yields an empty list, not an error', () async {
      expect(await repo.fetchExperts(), isEmpty);
    });

    test('NO filtering is done on name or email — approval is the only signal', () async {
      // An approved expert who genuinely has "test" in their name must stay
      // listed. Hiding by name was explicitly not acceptable.
      await expert('r1', name: 'Testa Bianchi', approved: true);
      await expert('r2', name: 'Protestant Nutrition Co', approved: true);

      final wouldShow =
          (await repo.fetchExperts()).where((e) => e.listedInMarketplace);
      expect(wouldShow.length, 2);
    });
  });

  group('direct profile lookup is NOT gated', () {
    test('an unapproved expert is still reachable by id', () async {
      // Requirement: Personal Coach and Request Review must keep working.
      // An athlete already engaged with an expert whose approval was revoked
      // must still be able to open that profile, or their live relationship
      // would break. Only the public LISTING is gated.
      await expert('test-uid', name: 'Test Email', approved: false);

      final one = await repo.fetchExpert('test-uid');
      expect(one, isNotNull);
      expect(one!.name, 'Test Email');
      expect(one.listedInMarketplace, isFalse);
    });

    test('a genuinely missing expert still returns null', () async {
      expect(await repo.fetchExpert('nobody'), isNull);
    });
  });
}
