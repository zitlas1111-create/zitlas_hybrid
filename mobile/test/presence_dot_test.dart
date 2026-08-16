import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/core/presence/presence_dot.dart';
import 'package:zitlas_mobile/core/presence/presence_repository.dart';
import 'package:zitlas_mobile/core/presence/presence_status.dart';
import 'package:zitlas_mobile/core/theme/zitlas_tokens.dart';

/// The RENDER side.
///
/// The expert dashboard used to paint its dot with `p?.isOnline ?? true` —
/// so a missing profile, a failed read and a user who has never been seen
/// all came out GREEN. These pin the opposite: nothing renders green
/// without a live heartbeat behind it.

class _FakeRepository extends PresenceRepository {
  final Map<String, StreamController<PresenceStatus>> controllers = {};

  @override
  Stream<PresenceStatus> watch(String uid) {
    return controllers
        .putIfAbsent(uid, () => StreamController<PresenceStatus>.broadcast())
        .stream;
  }

  void emit(String uid, PresenceStatus status) {
    controllers
        .putIfAbsent(uid, () => StreamController<PresenceStatus>.broadcast())
        .add(status);
  }

  void dispose() {
    for (final c in controllers.values) {
      c.close();
    }
  }
}

Color _dotColour(WidgetTester tester) {
  final container = tester.widget<Container>(
    find.descendant(of: find.byType(PresenceDot), matching: find.byType(Container)),
  );
  return ((container.decoration as BoxDecoration).color)!;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: child))));
  await _flush(tester);
}

/// A broadcast stream delivers in a microtask, which a single pump only
/// picks up for the very first event. Two pumps make every emit observable.
Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  late _FakeRepository repo;

  setUp(() => repo = _FakeRepository());
  tearDown(() => repo.dispose());

  testWidgets('before any data arrives the dot is GREY, not green', (tester) async {
    await _pump(tester, PresenceDot(uid: 'expert_1', repository: repo));
    await _flush(tester);
    expect(_dotColour(tester), ZitlasTokens.textMuted);
  });

  testWidgets('a live heartbeat turns the dot green', (tester) async {
    await _pump(tester, PresenceDot(uid: 'expert_1', repository: repo));
    repo.emit('expert_1', const PresenceStatus(isOnline: true, lastSeen: null));
    await _flush(tester);
    expect(_dotColour(tester), ZitlasTokens.success);
  });

  testWidgets('going offline turns the dot grey again without a rebuild', (tester) async {
    await _pump(tester, PresenceDot(uid: 'expert_1', repository: repo));
    repo.emit('expert_1', const PresenceStatus(isOnline: true, lastSeen: null));
    await _flush(tester);
    expect(_dotColour(tester), ZitlasTokens.success);

    repo.emit('expert_1', PresenceStatus.unknown);
    await _flush(tester);
    expect(_dotColour(tester), ZitlasTokens.textMuted);
  });

  testWidgets('a stale user renders grey', (tester) async {
    await _pump(tester, PresenceDot(uid: 'expert_1', repository: repo));
    repo.emit(
      'expert_1',
      PresenceStatus(isOnline: false, lastSeen: DateTime(2026, 1, 1)),
    );
    await _flush(tester);
    expect(_dotColour(tester), ZitlasTokens.textMuted);
  });

  testWidgets('changing uid re-subscribes instead of showing the previous person', (tester) async {
    await _pump(tester, PresenceDot(uid: 'expert_1', repository: repo));
    repo.emit('expert_1', const PresenceStatus(isOnline: true, lastSeen: null));
    await _flush(tester);
    expect(_dotColour(tester), ZitlasTokens.success);

    // expert_2 is offline; without didUpdateWidget re-subscribing, the dot
    // would keep rendering expert_1's green — a mix-up worse than no dot.
    await _pump(tester, PresenceDot(uid: 'expert_2', repository: repo));
    await _flush(tester);
    expect(_dotColour(tester), ZitlasTokens.textMuted);
  });

  testWidgets('PresenceBuilder exposes the label for callers that need it', (tester) async {
    await _pump(
      tester,
      PresenceBuilder(
        uid: 'expert_1',
        repository: repo,
        builder: (context, status) => Text(status.label()),
      ),
    );
    await _flush(tester);
    expect(find.text('Offline'), findsOneWidget);

    repo.emit('expert_1', const PresenceStatus(isOnline: true, lastSeen: null));
    await _flush(tester);
    expect(find.text('Online'), findsOneWidget);
  });
}
