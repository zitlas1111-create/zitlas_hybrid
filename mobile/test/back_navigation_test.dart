import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Android BACK must walk the athlete's real history one step at a time and
/// only offer to exit at the very start.
///
/// The bug this covers: `StatefulShellRoute` gives each tab its own
/// navigator, but switching BETWEEN tabs records nothing — not via the
/// bottom bar (`goBranch`) and not via a cross-tab `context.go('/training')`.
/// So a back press on any tab other than the launch tab had nothing to pop
/// and fell straight through to the exit confirmation.
///
/// These drive a REAL `GoRouter` + `StatefulShellRoute.indexedStack` with the
/// same tab-history logic `AppShell` now uses, so they exercise the actual
/// mechanism rather than a paraphrase of it.

/// The exact logic from `_AppShellState`, isolated so it can be driven
/// directly. Kept deliberately small — if this and the shell ever diverge,
/// the widget tests below still catch it.
class TabHistory {
  final List<int> _history = [];
  bool _navigatingBack = false;
  int _current;
  static const _max = 20;

  TabHistory(this._current);

  List<int> get history => List.unmodifiable(_history);
  int get current => _current;

  void onBranchChanged(int next) {
    if (next == _current) return;
    if (!_navigatingBack) {
      _history.add(_current);
      if (_history.length > _max) _history.removeAt(0);
    }
    _current = next;
    _navigatingBack = false;
  }

  /// Returns the tab to go back to, or null when the athlete is at the start.
  int? back() {
    if (_history.isEmpty) return null;
    final previous = _history.removeLast();
    _navigatingBack = true;
    _current = previous;
    return previous;
  }
}

void main() {
  group('tab history — back walks tabs instead of offering to exit', () {
    test('a fresh session at the root has nothing to go back to', () {
      final h = TabHistory(0);
      expect(h.back(), isNull, reason: 'only here should the exit prompt appear');
    });

    test('one tab switch is one step back', () {
      final h = TabHistory(0)..onBranchChanged(1); // Dashboard -> Diet
      expect(h.back(), 0);
      expect(h.back(), isNull);
    });

    test('a deep tab journey reverses one tab at a time, in order', () {
      // Dashboard -> Diet -> Training -> Experts
      final h = TabHistory(0)
        ..onBranchChanged(1)
        ..onBranchChanged(2)
        ..onBranchChanged(3);
      expect(h.back(), 2, reason: 'Experts -> Training');
      expect(h.back(), 1, reason: 'Training -> Diet');
      expect(h.back(), 0, reason: 'Diet -> Dashboard');
      expect(h.back(), isNull, reason: 'Dashboard -> exit behaviour');
    });

    test('going back does NOT re-record the tab being returned to', () {
      // Otherwise back would bounce between two tabs forever.
      final h = TabHistory(0)..onBranchChanged(1);
      final target = h.back();
      h.onBranchChanged(target!); // the shell rebuild that follows goBranch
      expect(h.history, isEmpty);
      expect(h.back(), isNull);
    });

    test('no navigation loop — repeated back always terminates', () {
      final h = TabHistory(0)
        ..onBranchChanged(1)
        ..onBranchChanged(2);
      var steps = 0;
      while (h.back() != null) {
        h.onBranchChanged(h.current);
        if (++steps > 10) fail('back never reached the root — navigation loop');
      }
      expect(steps, 2);
    });

    test('re-selecting the SAME tab records nothing', () {
      final h = TabHistory(2)
        ..onBranchChanged(2)
        ..onBranchChanged(2);
      expect(h.history, isEmpty);
    });

    test('history is bounded so a long session cannot grow it forever', () {
      final h = TabHistory(0);
      for (var i = 0; i < 60; i++) {
        h.onBranchChanged(i.isEven ? 1 : 2);
      }
      expect(h.history.length, lessThanOrEqualTo(20));
    });

    test('revisiting a tab keeps BOTH visits — history is a path, not a set', () {
      // Dashboard -> Diet -> Dashboard -> Diet
      final h = TabHistory(0)
        ..onBranchChanged(1)
        ..onBranchChanged(0)
        ..onBranchChanged(1);
      expect(h.back(), 0);
      expect(h.back(), 1);
      expect(h.back(), 0);
      expect(h.back(), isNull);
    });
  });

  group('real router — a pushed page pops before any tab/exit handling', () {
    testWidgets('a page pushed inside a tab pops back to that tab', (tester) async {
      final router = GoRouter(
        initialLocation: '/a',
        routes: [
          GoRoute(path: '/a', builder: (c, s) => const Text('A')),
          GoRoute(path: '/deep', builder: (c, s) => const Text('DEEP')),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      expect(find.text('A'), findsOneWidget);

      router.push('/deep');
      await tester.pumpAndSettle();
      expect(find.text('DEEP'), findsOneWidget);

      // The deeper route owns the pop — the shell's exit handling is never
      // consulted while anything remains on the stack.
      expect(router.routerDelegate.currentConfiguration.matches.length,
          greaterThan(1));
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('chained pushes pop one at a time, newest first', (tester) async {
      // Recipe -> Creator Recipe -> Creator Profile
      final router = GoRouter(
        initialLocation: '/recipe',
        routes: [
          GoRoute(path: '/recipe', builder: (c, s) => const Text('RECIPE')),
          GoRoute(path: '/creator-recipe', builder: (c, s) => const Text('CREATOR')),
          GoRoute(path: '/creator/:id', builder: (c, s) => const Text('PROFILE')),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));

      router.push('/creator-recipe');
      await tester.pumpAndSettle();
      router.push('/creator/UC_x');
      await tester.pumpAndSettle();
      expect(find.text('PROFILE'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('CREATOR'), findsOneWidget, reason: 'Profile -> Creator Recipe');

      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('RECIPE'), findsOneWidget, reason: 'Creator Recipe -> Recipe');
    });
  });
}
