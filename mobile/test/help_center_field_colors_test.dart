import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/app/theme.dart';
import 'package:zitlas_mobile/core/theme/zitlas_tokens.dart';
import 'package:zitlas_mobile/features/profile/presentation/screens/help_support_screen.dart';
import 'package:zitlas_mobile/features/support/data/support_repository.dart';
import 'package:zitlas_mobile/features/support/models/support_conversation.dart';

/// Verifies the ACTUAL RENDERED colours of the Help Center fields by pumping
/// the real screen under the real app theme, then reading the resolved styles
/// back off the element tree.
///
/// The app theme is `Brightness.dark` and is deliberately NOT modified — these
/// fields state their own colours locally. That is exactly what these tests
/// pin: the screen must be readable *despite* the dark global theme, so a
/// future theme change cannot silently make typing invisible again.
///
/// Three different Material slots are involved, which is what made the first
/// attempt at this fix miss the dropdown entirely:
///   * TextField typed text  -> textTheme.bodyLarge   (text_field.dart:1893)
///   * DropdownButton value  -> textTheme.titleMedium (dropdown.dart:1449)
///   * Dropdown menu surface -> canvasColor           (dropdown.dart:341)

/// A repository that never touches Firebase or the network.
class _StubRepo implements SupportRepository {
  @override
  Stream<List<SupportConversation>> watchConversations() =>
      Stream.value(const []);

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}


/// The colour actually PAINTED for a piece of text, after the widget's own
/// style and every inherited DefaultTextStyle have been resolved. Reading
/// `Text.style` alone is not enough: an InputDecorator supplies its hint
/// colour through an ancestor DefaultTextStyle, leaving `Text.style` null.
Color? paintedColor(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  return paragraph.text.style?.color;
}

Future<void> _openNewConversationSheet(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    theme: ZitlasTheme.dark, // the REAL app theme, unmodified
    home: HelpSupportScreen(repository: _StubRepo()),
  ));
  await tester.pumpAndSettle();

  await tester.tap(find.text('New Conversation'));
  await tester.pumpAndSettle();
}

void main() {
  group('the global theme is left alone', () {
    test('ThemeData is still the untouched dark theme', () {
      final theme = ZitlasTheme.dark;
      expect(theme.brightness, Brightness.dark);
      // If these ever become dark, someone edited the GLOBAL theme — which is
      // the change this task deliberately avoided.
      expect(theme.textTheme.bodyLarge?.color, const Color(0xFFFFFFFF));
      expect(theme.canvasColor, const Color(0xFF000000));
    });
  });

  group('"What do you need help with?" — Subject field', () {
    testWidgets('typed text renders near-black, not white', (tester) async {
      await _openNewConversationSheet(tester);

      final editables = tester.widgetList<EditableText>(find.byType(EditableText));
      expect(editables, isNotEmpty);
      for (final e in editables) {
        expect(e.style.color, ZitlasTokens.textPrimary);
        expect(e.style.color, isNot(const Color(0xFFFFFFFF)),
            reason: 'white typed text on the white field is the reported bug');
      }
    });

    testWidgets('the caret is dark and visible', (tester) async {
      await _openNewConversationSheet(tester);
      for (final e in tester.widgetList<EditableText>(find.byType(EditableText))) {
        expect(e.cursorColor, ZitlasTokens.textPrimary);
        expect(e.cursorColor, isNot(const Color(0xFFFFFFFF)));
      }
    });

    testWidgets('the placeholder is present and dark enough to read',
        (tester) async {
      await _openNewConversationSheet(tester);

      expect(find.text('What do you need help with?'), findsOneWidget);
      final c = paintedColor(tester, find.text('What do you need help with?'));
      expect(c, ZitlasTokens.textMuted);
      expect(c, isNot(const Color(0xFFFFFFFF)));
    });

    testWidgets('the Message placeholder is readable too', (tester) async {
      await _openNewConversationSheet(tester);
      expect(find.text('Describe your issue…'), findsOneWidget);
      expect(paintedColor(tester, find.text('Describe your issue…')),
          ZitlasTokens.textMuted);
    });
  });

  group('"Category" — the dropdown', () {
    testWidgets('the field label renders dark', (tester) async {
      await _openNewConversationSheet(tester);
      final c = paintedColor(tester, find.text('Category'));
      expect(c, isNot(const Color(0xFFFFFFFF)));
      expect(c, ZitlasTokens.textSecondary);
    });

    testWidgets('the SELECTED value renders dark, not white', (tester) async {
      await _openNewConversationSheet(tester);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Subscription').last);
      await tester.pumpAndSettle();

      // The closed field now shows the chosen value.
      final c = paintedColor(tester, find.text('Subscription'));
      expect(c, ZitlasTokens.textPrimary);
      expect(c, isNot(const Color(0xFFFFFFFF)),
          reason: 'the Category selection was rendering white on white');
    });

    testWidgets('every OPEN menu option renders dark', (tester) async {
      await _openNewConversationSheet(tester);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();

      const categories = [
        'Technical Issue',
        'Training Plan Issue',
        'Nutrition Plan Issue',
        'Account Problem',
        'Subscription',
        'Feature Request',
        'Other',
      ];

      for (final c in categories) {
        final finder = find.text(c);
        expect(finder, findsWidgets, reason: '"$c" should be in the menu');
        for (var i = 0; i < tester.widgetList<Text>(finder).length; i++) {
          expect(paintedColor(tester, finder.at(i)), ZitlasTokens.textPrimary,
              reason: '"$c" must be dark on the light menu');
        }
      }
    });

    testWidgets('the menu surface is light, so dark option text reads on it',
        (tester) async {
      await _openNewConversationSheet(tester);

      // DropdownButtonFormField forwards dropdownColor to the DropdownButton
      // it builds, which is where the menu is actually painted:
      // `dropdownColor ?? canvasColor` (dropdown.dart:341). canvasColor is
      // #000000, so this MUST be set locally or the menu goes black.
      final button =
          tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>));
      expect(button.dropdownColor, ZitlasTokens.bgCard);
      expect(button.dropdownColor, isNot(const Color(0xFF000000)));
      expect(button.style?.color, ZitlasTokens.textPrimary);
    });

    testWidgets('the dropdown hint reads before anything is picked',
        (tester) async {
      await _openNewConversationSheet(tester);
      expect(find.text('Select a category'), findsOneWidget);
      final c = paintedColor(tester, find.text('Select a category'));
      expect(c, ZitlasTokens.textMuted);
      expect(c, isNot(const Color(0xFFFFFFFF)));
    });
  });

  group('the fix is local, not global', () {
    testWidgets('the screen is readable even though the theme stays dark',
        (tester) async {
      await _openNewConversationSheet(tester);
      // Proves the readability comes from the widgets themselves: the theme
      // pumped above still reports white bodyLarge and a black canvas.
      expect(ZitlasTheme.dark.textTheme.bodyLarge?.color,
          const Color(0xFFFFFFFF));
      final e = tester.widgetList<EditableText>(find.byType(EditableText)).first;
      expect(e.style.color, ZitlasTokens.textPrimary);
    });
  });
}
