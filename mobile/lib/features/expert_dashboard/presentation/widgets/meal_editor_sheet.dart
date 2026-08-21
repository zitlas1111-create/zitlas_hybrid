import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../diet/models/diet_meal.dart';
import '../../data/food_search_repository.dart';
import 'food_search_sheet.dart';

/// Full meal editor: every food item and every nutrition value.
///
/// SCHEMA NOTE — the plan format stores `foods` as a list of DISPLAY STRINGS
/// (`"Poha (1 plate (200 g))"`), with calories/protein/carbs/fat held at the
/// MEAL level. That is the shape the generator produces, the website writes,
/// and the athlete's Diet screen renders. Per-food macros are therefore not
/// representable without a schema change that would break both other clients,
/// so this editor gives the expert full control over the food LIST (name +
/// quantity + unit per item, composed into that same display string) and over
/// the meal's own macro totals.
Future<DietMeal?> showMealEditorSheet(
  BuildContext context, {
  required DietMeal meal,
  FoodSearchRepository? foodRepository,
}) {
  return showModalBottomSheet<DietMeal>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _MealEditorSheet(meal: meal, foodRepository: foodRepository),
  );
}

/// One editable food line. [quantity]/[unit] are parsed out of the stored
/// display string so an expert edits real fields rather than punctuation.
class _FoodItem {
  _FoodItem({required this.name, this.quantity = '', this.unit = ''});

  String name;
  String quantity;
  String unit;

  /// `"Poha (1 plate (200 g))"` -> name `Poha`, quantity `1`, unit `plate (200 g)`.
  /// Anything that doesn't match falls back to the whole string as the name,
  /// so a hand-written entry is never mangled.
  static _FoodItem parse(String raw) {
    final text = raw.trim();
    final open = text.indexOf('(');
    if (open <= 0 || !text.endsWith(')')) return _FoodItem(name: text);
    final name = text.substring(0, open).trim();
    final inner = text.substring(open + 1, text.length - 1).trim();
    final match = RegExp(r'^([\d./]+)\s+(.*)$').firstMatch(inner);
    if (match == null) return _FoodItem(name: name, unit: inner);
    return _FoodItem(name: name, quantity: match.group(1)!, unit: match.group(2)!);
  }

  /// Recomposes the display string the rest of ZITLAS expects.
  String toDisplay() {
    final n = name.trim();
    final q = quantity.trim();
    final u = unit.trim();
    if (q.isEmpty && u.isEmpty) return n;
    if (q.isEmpty) return '$n ($u)';
    if (u.isEmpty) return '$n ($q)';
    return '$n ($q $u)';
  }

  _FoodItem copy() => _FoodItem(name: name, quantity: quantity, unit: unit);
}

class _MealEditorSheet extends StatefulWidget {
  const _MealEditorSheet({required this.meal, this.foodRepository});
  final DietMeal meal;
  final FoodSearchRepository? foodRepository;

  @override
  State<_MealEditorSheet> createState() => _MealEditorSheetState();
}

class _MealEditorSheetState extends State<_MealEditorSheet> {
  late final List<_FoodItem> _items =
      widget.meal.foods.map(_FoodItem.parse).toList();

  late final _calories = TextEditingController(text: _num(widget.meal.calories));
  late final _protein = TextEditingController(text: _num(widget.meal.proteinG));
  late final _carbs = TextEditingController(text: _num(widget.meal.carbsG));
  late final _fat = TextEditingController(text: _num(widget.meal.fatG));
  late final _notes = TextEditingController(text: widget.meal.notes ?? '');

  String? _error;

  static String _num(num? v) => v == null ? '' : (v % 1 == 0 ? v.toInt().toString() : v.toString());

  @override
  void dispose() {
    _calories.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    _notes.dispose();
    super.dispose();
  }

  // ── Food-list operations ────────────────────────────────────────────────

  Future<void> _addFromDatabase() async {
    final picked = await showFoodSearchSheet(
      context,
      title: 'Add Food',
      repository: widget.foodRepository,
    );
    if (picked == null) return;
    setState(() => _items.add(_FoodItem.parse(picked.display)));
  }

  Future<void> _swap(int index) async {
    final picked = await showFoodSearchSheet(
      context,
      title: 'Swap “${_items[index].name}”',
      repository: widget.foodRepository,
      initialQuery: '',
    );
    if (picked == null) return;
    setState(() => _items[index] = _FoodItem.parse(picked.display));
  }

  void _addBlank() => setState(() => _items.add(_FoodItem(name: '')));
  void _duplicate(int i) => setState(() => _items.insert(i + 1, _items[i].copy()));
  void _delete(int i) => setState(() => _items.removeAt(i));

  /// `onReorderItem` already accounts for the removed item, so unlike the
  /// deprecated `onReorder` this must NOT decrement newIndex itself.
  void _reorder(int oldIndex, int newIndex) {
    setState(() => _items.insert(newIndex, _items.removeAt(oldIndex)));
  }

  // ── Validation + save ───────────────────────────────────────────────────

  /// Returns an error message, or null when the meal is safe to send.
  String? _validate() {
    final named = _items.where((i) => i.name.trim().isNotEmpty).toList();
    if (named.isEmpty) return 'Add at least one food with a name.';
    if (_items.any((i) => i.name.trim().isEmpty)) {
      return 'Every food needs a name (or remove the empty row).';
    }
    for (final (label, ctrl) in [
      ('Calories', _calories),
      ('Protein', _protein),
      ('Carbs', _carbs),
      ('Fat', _fat),
    ]) {
      final text = ctrl.text.trim();
      if (text.isEmpty) continue;
      final value = num.tryParse(text);
      if (value == null) return '$label must be a number.';
      if (value < 0) return "$label can't be negative.";
    }
    // A plausibility ceiling, not a nutrition rule — it only catches a slipped
    // decimal point or an extra zero before it reaches the athlete.
    final cal = num.tryParse(_calories.text.trim());
    if (cal != null && cal > 5000) return 'Calories look too high for one meal.';
    return null;
  }

  void _save() {
    final error = _validate();
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final updated = widget.meal.copyWith(
      foods: _items.map((i) => i.toDisplay()).toList(),
      calories: num.tryParse(_calories.text.trim()),
      proteinG: num.tryParse(_protein.text.trim()),
      carbsG: num.tryParse(_carbs.text.trim()),
      fatG: num.tryParse(_fat.text.trim()),
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      edited: true,
      modifiedBy: 'Expert',
      modifiedAt: DateTime.now().toIso8601String(),
    );
    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.9,
        decoration: const BoxDecoration(
          color: ZitlasTokens.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            _header(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                children: [
                  _sectionLabel('Foods', trailing: '${_items.length} item${_items.length == 1 ? '' : 's'}'),
                  _foodList(),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _addFromDatabase,
                          icon: const Icon(Icons.search_rounded, size: 17),
                          label: const Text('Add from database'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.outlined(
                        tooltip: 'Add blank row',
                        onPressed: _addBlank,
                        icon: const Icon(Icons.add_rounded, size: 19),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _sectionLabel('Nutrition (whole meal)'),
                  Row(
                    children: [
                      Expanded(child: _numField(_calories, 'Calories', 'kcal')),
                      const SizedBox(width: 10),
                      Expanded(child: _numField(_protein, 'Protein', 'g')),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: _numField(_carbs, 'Carbs', 'g')),
                      const SizedBox(width: 10),
                      Expanded(child: _numField(_fat, 'Fat', 'g')),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _sectionLabel('Notes for the user'),
                  TextField(
                    controller: _notes,
                    maxLines: 3,
                    decoration: _decoration('e.g. Have this within 30 min of training'),
                  ),
                ],
              ),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Column(
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: ZitlasTokens.borderSub,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.meal.mealName,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: ZitlasTokens.textPrimary,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: ZitlasTokens.textSecondary),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: ZitlasTokens.borderSub)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Pinned with the button rather than at the end of the scrollable
          // body: the expert taps Save from down here, and an error rendered
          // above the fold reads as "nothing happened".
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded,
                      size: 17, color: ZitlasTokens.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: ZitlasTokens.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: ZitlasTokens.primary,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _save,
              child: const Text(
                'Save Meal',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text, {String? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(
        children: [
          Text(
            text.toUpperCase(),
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.7,
              color: ZitlasTokens.textMuted,
            ),
          ),
          const Spacer(),
          if (trailing != null)
            Text(trailing, style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted)),
        ],
      ),
    );
  }

  /// Drag-to-reorder list of food rows.
  Widget _foodList() {
    if (_items.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 22),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ZitlasTokens.borderSub),
        ),
        child: const Text(
          'No foods yet — add one below.',
          style: TextStyle(fontSize: 12.5, color: ZitlasTokens.textMuted),
        ),
      );
    }
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: _items.length,
      onReorderItem: _reorder,
      itemBuilder: (context, i) => _FoodRow(
        // IDENTITY key, never content. A key containing the food name changes
        // on every keystroke, which makes Flutter tear down this row's State —
        // taking its TextEditingController and the TextField's focus with it,
        // so the keyboard closes after each character. `_FoodItem` is a
        // mutable object whose identity survives a rename, and stays unique
        // across duplicate (which copies) and reorder (which moves the same
        // instances), so ObjectKey is both stable and correct here.
        key: ObjectKey(_items[i]),
        index: i,
        item: _items[i],
        onSwap: () => _swap(i),
        onDuplicate: () => _duplicate(i),
        onDelete: () => _delete(i),
      ),
    );
  }

  Widget _numField(TextEditingController c, String label, String suffix) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      // Blocks a negative value at the keyboard rather than only at save —
      // the expert never gets to type something the plan can't hold.
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      decoration: _decoration(label, suffix: suffix),
    );
  }

  InputDecoration _decoration(String label, {String? suffix}) {
    return InputDecoration(
      labelText: label,
      suffixText: suffix,
      isDense: true,
      filled: true,
      fillColor: ZitlasTokens.bgCardLight,
      labelStyle: const TextStyle(fontSize: 12.5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }
}

/// One food row: name + quantity + unit, with per-row actions.
class _FoodRow extends StatefulWidget {
  const _FoodRow({
    super.key,
    required this.index,
    required this.item,
    required this.onSwap,
    required this.onDuplicate,
    required this.onDelete,
  });

  final int index;
  final _FoodItem item;
  final VoidCallback onSwap;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  State<_FoodRow> createState() => _FoodRowState();
}

class _FoodRowState extends State<_FoodRow> {
  late final _name = TextEditingController(text: widget.item.name);
  late final _qty = TextEditingController(text: widget.item.quantity);
  late final _unit = TextEditingController(text: widget.item.unit);

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _unit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCardLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZitlasTokens.borderSub),
      ),
      child: Column(
        children: [
          Row(
            children: [
              ReorderableDragStartListener(
                index: widget.index,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.drag_indicator_rounded,
                      size: 18, color: ZitlasTokens.textMuted),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _name,
                  // Writes straight into the mutable model the parent reads
                  // at save time. Deliberately NO setState: rebuilding the
                  // list on every keystroke is what tore this row down and
                  // closed the keyboard, and nothing on screen depends on the
                  // name while it's being typed.
                  onChanged: (v) => widget.item.name = v,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(
                    hintText: 'Food name',
                    isDense: true,
                    border: InputBorder.none,
                  ),
                ),
              ),
              _iconAction(Icons.swap_horiz_rounded, 'Swap', widget.onSwap),
              _iconAction(Icons.copy_rounded, 'Duplicate', widget.onDuplicate),
              _iconAction(Icons.delete_outline_rounded, 'Delete', widget.onDelete,
                  danger: true),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 30, right: 6, top: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 68,
                  child: TextField(
                    controller: _qty,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9./]')),
                    ],
                    onChanged: (v) => widget.item.quantity = v,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: 'Qty',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _unit,
                    onChanged: (v) => widget.item.unit = v,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: 'Unit (e.g. bowl (150 g))',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconAction(IconData icon, String tooltip, VoidCallback onTap,
      {bool danger = false}) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      icon: Icon(icon,
          size: 17, color: danger ? ZitlasTokens.danger : ZitlasTokens.textSecondary),
      onPressed: onTap,
    );
  }
}
