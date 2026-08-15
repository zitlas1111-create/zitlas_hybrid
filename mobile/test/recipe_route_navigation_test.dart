import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Rules out a specific hypothesis raised while investigating "a meal card's
/// recipe button showed the wrong slot's content": that pushing `/recipe`
/// twice in a row with a DIFFERENT `meal_type` query value reuses the same
/// State object (so a stale `late` field from the first push — e.g.
/// RecipeScreen's `_mealType` — survives into the second). If GoRouter ever
/// reused the page/state here, `initState()` would not re-run and the
/// second navigation would silently keep showing the first meal's content.
///
/// This test exercises the REAL router mechanics (a real GoRouter + real
/// Navigator, pushing the actual `/recipe` path twice with different query
/// values) against a minimal stand-in screen — not the real RecipeScreen,
/// which needs Firebase/network — so it isolates the ROUTING behavior from
/// RecipeScreen's own internals (already covered separately by recipe_test.dart
/// and meal_slot_test.dart).
void main() {
  testWidgets('pushing /recipe with a different meal_type each time creates a FRESH screen instance', (tester) async {
    final initCalls = <String>[];

    final router = GoRouter(
      initialLocation: '/diet',
      routes: [
        GoRoute(path: '/diet', builder: (context, state) => const _DietStub()),
        GoRoute(
          path: '/recipe',
          builder: (context, state) => _RecipeStub(
            mealType: state.uri.queryParameters['meal_type'] ?? 'snack',
            onInit: (mealType) => initCalls.add(mealType),
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    // Simulate tapping the Breakfast card's "Get Easy Recipe" button.
    router.push('/recipe?meal_type=breakfast');
    await tester.pumpAndSettle();
    expect(find.text('mealType=breakfast'), findsOneWidget);
    expect(initCalls, ['breakfast']);

    // Back to the Diet screen — a real user action between the two taps.
    router.pop();
    await tester.pumpAndSettle();

    // Now tap the Pre-Workout card's "Get Workout Fuel" button.
    router.push('/recipe?meal_type=pre_workout');
    await tester.pumpAndSettle();
    expect(find.text('mealType=pre_workout'), findsOneWidget);

    // The critical assertion: initState() ran AGAIN for the second push
    // (a reused State object would only have ['breakfast'] here, and the
    // screen would still be showing "mealType=breakfast").
    expect(initCalls, ['breakfast', 'pre_workout']);
  });

  testWidgets('pushing /recipe for pre_workout then post_workout never shows stale content', (tester) async {
    final router = GoRouter(
      initialLocation: '/diet',
      routes: [
        GoRoute(path: '/diet', builder: (context, state) => const _DietStub()),
        GoRoute(
          path: '/recipe',
          builder: (context, state) => _RecipeStub(
            mealType: state.uri.queryParameters['meal_type'] ?? 'snack',
            onInit: (_) {},
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    router.push('/recipe?meal_type=pre_workout');
    await tester.pumpAndSettle();
    expect(find.text('mealType=pre_workout'), findsOneWidget);
    expect(find.text('mealType=post_workout'), findsNothing);

    router.pop();
    await tester.pumpAndSettle();

    router.push('/recipe?meal_type=post_workout');
    await tester.pumpAndSettle();
    expect(find.text('mealType=post_workout'), findsOneWidget);
    expect(find.text('mealType=pre_workout'), findsNothing);
  });
}

class _DietStub extends StatelessWidget {
  const _DietStub();
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('Diet'));
}

class _RecipeStub extends StatefulWidget {
  const _RecipeStub({required this.mealType, required this.onInit});
  final String mealType;
  final void Function(String) onInit;

  @override
  State<_RecipeStub> createState() => _RecipeStubState();
}

class _RecipeStubState extends State<_RecipeStub> {
  @override
  void initState() {
    super.initState();
    widget.onInit(widget.mealType);
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: Text('mealType=${widget.mealType}'));
}
