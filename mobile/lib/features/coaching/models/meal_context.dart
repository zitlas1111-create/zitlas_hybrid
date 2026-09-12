import 'package:flutter/foundation.dart';

/// The foods offered as one tap on "What is this meal?".
///
/// The website's `MEAL_QUICK_ITEMS` in pages/diet/diet.js is the same list in
/// the same order, so a meal reads the same whichever client sent it.
const kMealQuickItems = <String>[
  'Biryani',
  'Chicken',
  'Paratha',
  'Rice',
  'Dal',
  'Eggs',
  'Salad',
  'Roti',
  'Vegetables',
  'Paneer',
];

/// Longest custom meal name — the same ceiling as the Help Center's one-line
/// subject (help_support_screen.dart). A meal NAME, not an essay; the website
/// enforces the same limit (`MEAL_CUSTOM_MAX`).
const kMealCustomMaxLength = 200;

/// What the ATHLETE says the meal is, stored on the check-in as
/// `meal_checkins/{id}.mealContext` and shown to the coach beside the photo:
///
///     { items: ["Chicken", "Rice"], custom: null,
///       description: "Chicken + Rice", source: "user" }
///
/// User-provided context — never an AI guess and never interpreted. It is
/// displayed as plain text, exactly as entered apart from surrounding spaces.
@immutable
class MealContext {
  const MealContext({this.items = const [], this.custom}) : _stored = null;

  const MealContext._(this.items, this.custom, this._stored);

  /// Quick picks, in the order tapped, without duplicates.
  final List<String> items;

  /// The athlete's own words (from "Other"), trimmed, otherwise exact.
  final String? custom;

  /// A description as another client wrote it, preferred for display so the
  /// coach sees exactly what was sent.
  final String? _stored;

  static const source = 'user';

  /// "Chicken + Rice", "Chicken curry with steamed rice", or both, joined.
  String get description {
    final stored = _stored;
    if (stored != null) return stored;
    final c = custom;
    final parts = [...items];
    if (c != null && c.isNotEmpty && !items.any((i) => i.toLowerCase() == c.toLowerCase())) {
      parts.add(c);
    }
    return parts.join(' + ');
  }

  bool get isEmpty => description.isEmpty;

  Map<String, dynamic> toMap() => {
        'items': items,
        'custom': custom,
        'description': description,
        'source': source,
      };

  /// Null for a check-in sent before this existed — those have no
  /// `mealContext` at all, and must keep rendering exactly as they did.
  static MealContext? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final items = <String>[
      if (raw['items'] is List)
        for (final i in raw['items'] as List)
          if (i is String && i.trim().isNotEmpty) i.trim(),
    ];
    final rawCustom = raw['custom'];
    final custom =
        rawCustom is String && rawCustom.trim().isNotEmpty ? rawCustom.trim() : null;
    final stored = raw['description'];
    if (stored is String && stored.trim().isNotEmpty) {
      return MealContext._(items, custom, stored.trim());
    }
    final composed = MealContext(items: items, custom: custom);
    return composed.isEmpty ? null : composed;
  }
}

/// The confirmation step's answer turned into a [MealContext] — or the one
/// thing to fix first. Shared by the sheet and its tests, so the rules are
/// written once:
///
///   * duplicates are dropped (case-insensitively), keeping tap order;
///   * "Other" with nothing typed is refused, never guessed;
///   * the custom name is trimmed and length-checked, otherwise kept exact;
///   * at least one quick pick OR a custom name is required.
({MealContext? context, String? error}) buildMealContext({
  required List<String> selected,
  required bool otherSelected,
  required String customText,
}) {
  final items = <String>[];
  for (final s in selected) {
    final t = s.trim();
    if (t.isEmpty || items.any((i) => i.toLowerCase() == t.toLowerCase())) continue;
    items.add(t);
  }
  // Text typed and then hidden by unselecting "Other" is not part of the
  // answer — only what is on screen is sent.
  final custom = otherSelected ? customText.trim() : '';
  if (otherSelected && custom.isEmpty) {
    return (context: null, error: 'Enter a meal name, or unselect Other.');
  }
  if (custom.length > kMealCustomMaxLength) {
    return (
      context: null,
      error: 'Keep the meal name within $kMealCustomMaxLength characters.',
    );
  }
  if (items.isEmpty && custom.isEmpty) {
    return (context: null, error: 'Pick what this meal is, or type it in.');
  }
  return (
    context: MealContext(items: items, custom: custom.isEmpty ? null : custom),
    error: null,
  );
}
