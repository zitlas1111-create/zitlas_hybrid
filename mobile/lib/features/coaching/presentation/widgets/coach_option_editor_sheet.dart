import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../models/coach_diet_plan.dart';

/// Edits one food option's macros, quantity and coach note.
///
/// Returns the edited option, or null if dismissed. Every macro field may be
/// left BLANK: a coach who hasn't measured the carbs has not said "zero
/// carbs", and storing 0 would quietly corrupt the day's totals. Blank stays
/// blank all the way to Firestore.
Future<CoachMealOption?> showCoachOptionEditorSheet(
  BuildContext context, {
  required CoachMealOption option,
  required String mealName,
}) {
  return showModalBottomSheet<CoachMealOption>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CoachOptionEditorSheet(option: option, mealName: mealName),
  );
}

class _CoachOptionEditorSheet extends StatefulWidget {
  const _CoachOptionEditorSheet({required this.option, required this.mealName});

  final CoachMealOption option;
  final String mealName;

  @override
  State<_CoachOptionEditorSheet> createState() => _CoachOptionEditorSheetState();
}

class _CoachOptionEditorSheetState extends State<_CoachOptionEditorSheet> {
  late final _name = TextEditingController(text: widget.option.name);
  late final _calories = TextEditingController(text: _text(widget.option.calories));
  late final _protein = TextEditingController(text: _text(widget.option.protein));
  late final _carbs = TextEditingController(text: _text(widget.option.carbs));
  late final _fat = TextEditingController(text: _text(widget.option.fat));
  late final _notes = TextEditingController(text: widget.option.notes ?? '');

  String? _error;

  static String _text(num? v) {
    if (v == null) return '';
    return v == v.roundToDouble() ? v.round().toString() : v.toString();
  }

  @override
  void dispose() {
    for (final c in [_name, _calories, _protein, _carbs, _fat, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'A food needs a name.');
      return;
    }
    Navigator.of(context).pop(
      widget.option.copyWith(
        name: name,
        calories: _num(_calories.text),
        protein: _num(_protein.text),
        carbs: _num(_carbs.text),
        fat: _num(_fat.text),
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      ),
    );
  }

  /// Blank -> null (unknown), not 0.
  static num? _num(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    return num.tryParse(t);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: ZitlasTokens.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
              const SizedBox(height: 16),
              Text(
                'Edit food',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: ZitlasTokens.textPrimary,
                ),
              ),
              Text(
                widget.mealName,
                style: const TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary),
              ),
              const SizedBox(height: 14),
              _Field(controller: _name, label: 'Food / quantity', autofocus: false),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _Field(controller: _calories, label: 'Calories', numeric: true)),
                  const SizedBox(width: 10),
                  Expanded(child: _Field(controller: _protein, label: 'Protein (g)', numeric: true)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _Field(controller: _carbs, label: 'Carbs (g)', numeric: true)),
                  const SizedBox(width: 10),
                  Expanded(child: _Field(controller: _fat, label: 'Fat (g)', numeric: true)),
                ],
              ),
              const SizedBox(height: 10),
              _Field(controller: _notes, label: 'Note for the user', maxLines: 2),
              const SizedBox(height: 6),
              const Text(
                'Leave a macro blank if you haven\'t measured it — it stays blank '
                'rather than counting as zero.',
                style: TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted, height: 1.4),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 12, color: ZitlasTokens.danger),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: ZitlasTokens.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
                  ),
                  child: const Text(
                    'Done',
                    style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    this.numeric = false,
    this.maxLines = 1,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;
  final bool numeric;
  final int maxLines;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      maxLines: maxLines,
      keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true) : null,
      inputFormatters:
          numeric ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))] : null,
      style: const TextStyle(fontSize: 13.5, color: ZitlasTokens.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary),
        filled: true,
        fillColor: ZitlasTokens.bgCardLight,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: ZitlasTokens.borderSub),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: ZitlasTokens.borderSub),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: ZitlasTokens.primary),
        ),
      ),
    );
  }
}
