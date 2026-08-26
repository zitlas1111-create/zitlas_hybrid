import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/app/theme.dart';
import 'package:zitlas_mobile/core/theme/zitlas_tokens.dart';

/// TEXT MUST BE READABLE ON THE SURFACE IT ACTUALLY SITS ON.
///
/// THE BUG THIS PINS
/// -----------------
/// `MaterialApp.theme` was `ZitlasTheme.dark` — `Brightness.dark`, white
/// default text — left over from before the light rebrand. Meanwhile 89
/// files had migrated to the LIGHT tokens in `core/theme/zitlas_tokens.dart`
/// and paint white cards and cream backgrounds.
///
/// So every widget that did not name a colour inherited WHITE and drew it on
/// a light surface. It was never a handful of stray `Colors.white`: it was
/// the DEFAULT. Concretely, in `meal_snap_button.dart`:
///
///     label: Text(controller.snappingMeal ? 'Sending…' : 'Snap Meal')
///     title: const Text('Take a photo')        // inside a bottom sheet
///     content: Text('📷 Sent to your coach…')  // inside a SnackBar
///
/// none of which names a colour. Same for the survey option labels on
/// Medical Conditions. Fixing those screens one by one would have left the
/// next new screen broken identically, so the DEFAULT is what changed.
///
/// These tests read the colours Flutter actually resolves for real widgets
/// under the real theme — not the token constants, which would prove nothing
/// about what a `Text` with no style ends up painting.
void main() {
  /// Perceived brightness, 0 (black) .. 1 (white).
  double lum(Color c) => c.computeLuminance();

  /// WCAG contrast ratio between two opaque colours.
  double contrast(Color fg, Color bg) {
    final a = lum(fg), b = lum(bg);
    final hi = a > b ? a : b, lo = a > b ? b : a;
    return (hi + 0.05) / (lo + 0.05);
  }

  const minBodyContrast = 4.5; // WCAG AA for body text

  group('the app-wide theme is light', () {
    test('brightness is light, not the legacy dark', () {
      expect(ZitlasTheme.light.brightness, Brightness.light,
          reason: 'a dark ThemeData is what made every unstyled Text white');
    });

    test('dark still resolves to light, so old call sites are safe', () {
      expect(ZitlasTheme.dark.brightness, Brightness.light);
    });

    test('default body text is dark on the scaffold background', () {
      final t = ZitlasTheme.light;
      final fg = t.textTheme.bodyMedium!.color!;
      final bg = t.scaffoldBackgroundColor;
      expect(contrast(fg, bg), greaterThan(minBodyContrast),
          reason: 'body text $fg on $bg is unreadable');
    });

    test('onSurface is dark against surface', () {
      final cs = ZitlasTheme.light.colorScheme;
      expect(contrast(cs.onSurface, cs.surface), greaterThan(minBodyContrast));
    });

    test('white on the green primary is still correct', () {
      final cs = ZitlasTheme.light.colorScheme;
      expect(cs.onPrimary, const Color(0xFFFFFFFF));
      expect(contrast(cs.onPrimary, cs.primary), greaterThan(minBodyContrast),
          reason: 'the button label must stay readable on dark green');
    });
  });

  group('the surfaces that were unreadable', () {
    /// Renders [child] under the real theme and returns the colour the given
    /// text ACTUALLY resolves to.
    Future<Color> resolvedTextColor(
      WidgetTester tester,
      Widget child,
      String text,
    ) async {
      await tester.pumpWidget(MaterialApp(
        theme: ZitlasTheme.light,
        home: child,
      ));
      await tester.pumpAndSettle();
      final widget = tester.widget<Text>(find.text(text));
      final ctx = tester.element(find.text(text));
      final style = widget.style ?? const TextStyle();
      final effective = DefaultTextStyle.of(ctx).style.merge(style);
      return effective.color ?? Theme.of(ctx).textTheme.bodyMedium!.color!;
    }

    testWidgets('a bare Text on a card is dark — the Meal Snap case',
        (tester) async {
      final c = await resolvedTextColor(
        tester,
        const Scaffold(
          backgroundColor: ZitlasTokens.bgCard,
          body: Center(child: Text('Sending…')),
        ),
        'Sending…',
      );
      expect(contrast(c, ZitlasTokens.bgCard), greaterThan(minBodyContrast),
          reason: 'this Text names no colour — exactly like '
              'meal_snap_button.dart line 44');
    });

    testWidgets('a ListTile title in a bottom sheet is dark', (tester) async {
      final c = await resolvedTextColor(
        tester,
        const Scaffold(
          backgroundColor: ZitlasTokens.bgCard,
          body: ListTile(title: Text('Take a photo')),
        ),
        'Take a photo',
      );
      expect(contrast(c, ZitlasTokens.bgCard), greaterThan(minBodyContrast),
          reason: 'the Meal Snap source picker was white on white');
    });

    testWidgets('a survey option label is dark — Medical Conditions',
        (tester) async {
      final c = await resolvedTextColor(
        tester,
        const Scaffold(
          backgroundColor: ZitlasTokens.bgCard,
          body: Row(children: [
            Checkbox(value: true, onChanged: null),
            Text('Diabetes'),
          ]),
        ),
        'Diabetes',
      );
      expect(contrast(c, ZitlasTokens.bgCard), greaterThan(minBodyContrast));
    });

    testWidgets('dialog and bottom-sheet surfaces are light', (tester) async {
      final t = ZitlasTheme.light;
      expect(lum(t.dialogTheme.backgroundColor!), greaterThan(0.5));
      expect(lum(t.bottomSheetTheme.backgroundColor!), greaterThan(0.5));
      // ...and their text is dark against it.
      expect(
        contrast(t.dialogTheme.contentTextStyle!.color!,
            t.dialogTheme.backgroundColor!),
        greaterThan(minBodyContrast),
      );
    });

    testWidgets('a TextField hint is readable on its fill', (tester) async {
      final t = ZitlasTheme.light;
      final hint = t.inputDecorationTheme.hintStyle!.color!;
      final fill = t.inputDecorationTheme.fillColor!;
      expect(contrast(hint, fill), greaterThan(3.0),
          reason: 'hint text is allowed to be softer than body, but not '
              'invisible');
    });
  });

  group('white that is CORRECT stays white', () {
    test('a snackbar is a dark slab with white text, deliberately', () {
      final s = ZitlasTheme.light.snackBarTheme;
      expect(lum(s.backgroundColor!), lessThan(0.2), reason: 'must stay dark');
      expect(s.contentTextStyle!.color, const Color(0xFFFFFFFF));
      expect(contrast(s.contentTextStyle!.color!, s.backgroundColor!),
          greaterThan(minBodyContrast));
    });

    test('a checkbox tick is white on the filled green box', () {
      final cb = ZitlasTheme.light.checkboxTheme;
      final tick = cb.checkColor!.resolve({WidgetState.selected})!;
      final box = cb.fillColor!.resolve({WidgetState.selected})!;
      expect(tick, const Color(0xFFFFFFFF));
      expect(contrast(tick, box), greaterThan(minBodyContrast),
          reason: 'the TICK is white on green — correct; it was the LABEL '
              'beside it that was unreadable');
    });

    test('the elevated button keeps a white label on dark green', () {
      final cs = ZitlasTheme.light.colorScheme;
      expect(contrast(const Color(0xFFFFFFFF), cs.primary),
          greaterThan(minBodyContrast));
    });
  });

  group('the dark surfaces that remain are still dark', () {
    test('the splash palette is unchanged', () {
      // ZitlasColors is the DELIBERATELY dark palette (splash, loading ring),
      // matching android/app/src/main/res/values/colors.xml. Its white text
      // is correct and must not be "fixed".
      expect(ZitlasColors.bgPrimary, const Color(0xFF000000));
      expect(ZitlasColors.textPrimary, const Color(0xFFFFFFFF));
      expect(contrast(ZitlasColors.textPrimary, ZitlasColors.bgPrimary),
          greaterThan(minBodyContrast));
    });
  });
}
