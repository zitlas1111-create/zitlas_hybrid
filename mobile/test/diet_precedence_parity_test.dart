import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/diet/diet_precedence.dart';

/// ONE diet precedence rule — the app side.
///
/// Runs EVERY case in `tests/fixtures/diet_precedence_cases.json` (repository
/// root) against `lib/features/diet/diet_precedence.dart`. The website runs
/// the SAME file against `assets/js/diet-precedence.js`
/// (`tests/js/diet-precedence-parity.test.mjs`), so for identical Firestore
/// state the website and the app choose the same diet.

final Map<String, dynamic> _fixture =
    jsonDecode(File('../tests/fixtures/diet_precedence_cases.json').readAsStringSync())
        as Map<String, dynamic>;

Object? _clone(Object? v) => jsonDecode(jsonEncode(v));

/// "$NAME" -> defs.NAME; {"$ref": "NAME", ...} -> defs.NAME with the rest on top.
Object? _resolve(Object? v) {
  final defs = _fixture['defs'] as Map<String, dynamic>;
  if (v is String && v.startsWith(r'$')) {
    final name = v.substring(1);
    if (!defs.containsKey(name)) throw StateError('unknown def $v');
    return _resolve(_clone(defs[name]));
  }
  if (v is List) return v.map(_resolve).toList();
  if (v is Map) {
    final out = <String, dynamic>{};
    final ref = v[r'$ref'];
    if (ref is String) {
      if (!defs.containsKey(ref)) throw StateError('unknown def $ref');
      out.addAll((_resolve(_clone(defs[ref])) as Map).cast<String, dynamic>());
    }
    v.forEach((k, x) {
      if (k != r'$ref') out[k as String] = _resolve(x);
    });
    return out;
  }
  return v;
}

Map<String, dynamic>? _map(Object? v) => v is Map ? v.cast<String, dynamic>() : null;

DietSource _select(Map<String, dynamic> state) => selectDietSource(DietPrecedenceInput.fromRaw(
      relationship: _map(state['relationship']),
      coachingPlan: _map(state['coachingPlan']),
      dietPlan: state['dietPlan'],
      dietPlanMaster: state['dietPlanMaster'],
      livePlanId: state['livePlanId'],
      now: state['now'],
      // `localCache` is deliberately never passed — the rule has no such input.
    ));

void main() {
  final cases = (_fixture['cases'] as List).cast<Map<String, dynamic>>();

  group('the shared precedence fixture (identical on the website)', () {
    for (final c in cases) {
      test(c['name'] as String, () {
        final state = _resolve(c['state']) as Map<String, dynamic>;
        expect(_select(state).wire, c['expected']);
      });
    }
  });

  test('the fixture covers every source and every name is unique', () {
    final names = cases.map((c) => c['name']).toList();
    expect(names.toSet().length, names.length);
    expect(cases.map((c) => c['expected']).toSet(),
        {'coach', 'expert', 'ai', 'ai_master', 'none'});
  });

  test('a Firestore Timestamp end date is read like an ISO one', () {
    final state = _resolve(cases.first['state']) as Map<String, dynamic>;
    final rel = _map(state['relationship'])!..remove('endDate');
    rel['endDateTs'] = Timestamp.fromDate(DateTime.parse('2026-09-13T11:00:00Z'));
    state['relationship'] = rel;
    expect(_select(state), DietSource.ai);
    rel['endDateTs'] = Timestamp.fromDate(DateTime.parse('2026-09-20T00:00:00Z'));
    expect(_select(state), DietSource.coach);
  });

  test('the website and the app implement the same five sources', () {
    final js = File('../frontend/website/assets/js/diet-precedence.js').readAsStringSync();
    for (final s in DietSource.values) {
      expect(js, contains("'${s.wire}'"), reason: s.wire);
    }
  });
}
