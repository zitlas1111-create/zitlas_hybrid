import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../diet_controller.dart';
import '../../models/diet_meal.dart';
import '../../models/swap_result.dart';

/// Native rebuild of `#swapModal` (`frontend/pages/diet/diet.js:848-1260`) —
/// the REAL website's 3-phase swap flow: Phase A asks WHY before anything
/// else, Phase B is the loading state, Phase C previews the suggestion with
/// Try Again / Accept. The 7 reason options and their exact copy are
/// word-for-word from the website (`diet.html:332-388`) — not invented.
Future<void> showMealSwapSheet(
  BuildContext context, {
  required DietController controller,
  required int dayIndex,
  required int mealIndex,
  required DietMeal meal,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _MealSwapSheet(
      controller: controller,
      dayIndex: dayIndex,
      mealIndex: mealIndex,
      meal: meal,
    ),
  );
}

/// `data-reason` values ported verbatim — the backend keyword-matches on
/// this exact text (`groq_service._build_reason_context`/
/// `_diet_type_from_reason`), so the wording is load-bearing, not cosmetic.
const kDietSwapReasons = <(String icon, String title, String desc, String reason)>[
  ('📍', 'Not Available', "Can't get this where I live", 'Not available near me'),
  ('💸', 'Too Expensive', 'Out of my daily budget', 'Too expensive for my budget'),
  ('🏫', "Hostel Doesn't Provide", 'Not served in my mess', "My hostel mess doesn't provide this"),
  ('😬', "Don't Like It", 'Not a fan of this', "I don't like this food"),
  ('⚠️', 'Allergic', "I can't eat this for health reasons", 'I am allergic to this'),
  ('🌿', 'Vegetarian Option', "I don't eat meat or non-veg", 'I am vegetarian and need a veg option'),
  ('🙏', 'Religious / Cultural', 'Not allowed for me to eat this', 'Religious or cultural reason'),
];

class _MealSwapSheet extends StatefulWidget {
  const _MealSwapSheet({
    required this.controller,
    required this.dayIndex,
    required this.mealIndex,
    required this.meal,
  });

  final DietController controller;
  final int dayIndex;
  final int mealIndex;
  final DietMeal meal;

  @override
  State<_MealSwapSheet> createState() => _MealSwapSheetState();
}

enum _SwapPhase { reason, loading, result }

class _MealSwapSheetState extends State<_MealSwapSheet> {
  _SwapPhase _phase = _SwapPhase.reason;
  String? _reason;
  final List<String> _rejectedFoods = [];
  final List<Map<String, dynamic>> _previousSuggestions = [];

  String? _error;

  /// The engine's full ranked result. Held verbatim — the sheet renders what
  /// the backend sent, in the order it sent it, and never re-ranks or filters.
  SwapResult? _result;
  int _selected = 0;

  Future<void> _selectReason(String reason) async {
    setState(() {
      _reason = reason;
      _phase = _SwapPhase.loading;
      _error = null;
    });
    final result = await widget.controller.requestMealSwap(
      dayIndex: widget.dayIndex,
      mealIndex: widget.mealIndex,
      reason: reason,
      rejectedFoods: _rejectedFoods,
      previousSuggestions: _previousSuggestions,
    );
    if (!mounted) return;
    setState(() {
      if (result == null || result.isEmpty) {
        _phase = _SwapPhase.reason;
        _error = 'Could not get a suggestion. Please try again.';
      } else {
        _phase = _SwapPhase.result;
        _result = result;
        _selected = 0;
        // Every option shown counts as "already offered", so Try Again gets a
        // genuinely fresh set rather than reshuffling the same five.
        for (final o in result.options) {
          _previousSuggestions.add({'foods': o.foods});
        }
      }
    });
  }

  void _tryAgain() {
    if (widget.meal.foods.isNotEmpty) _rejectedFoods.addAll(widget.meal.foods);
    final reason = _reason;
    if (reason == null) return;
    setState(() => _phase = _SwapPhase.loading);
    _selectReason(reason);
  }

  Future<void> _accept() async {
    final result = _result;
    if (result == null || result.isEmpty) return;
    final chosen = result.options[_selected];
    // Rebuilt into the shape acceptSwap() already persists — the engine's own
    // numbers, not anything recomputed here.
    final suggestion = <String, dynamic>{
      'name': chosen.name,
      'foods': chosen.foods,
      'calories': chosen.calories,
      'protein_g': chosen.proteinG,
      'carbs_g': chosen.carbsG,
      'fat_g': chosen.fatG,
      'reason': chosen.reason,
    };
    setState(() => _phase = _SwapPhase.loading);
    try {
      await widget.controller.acceptSwap(
        dayIndex: widget.dayIndex,
        mealIndex: widget.mealIndex,
        swap: suggestion,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _SwapPhase.result;
          _error = 'Could not save the swap: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        decoration: const BoxDecoration(
          color: ZitlasTokens.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(color: ZitlasTokens.borderSub, borderRadius: BorderRadius.circular(4)),
                ),
              ),
              const SizedBox(height: 16),
              _buildPhase(context),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(fontSize: 12, color: ZitlasTokens.danger)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPhase(BuildContext context) {
    switch (_phase) {
      case _SwapPhase.reason:
        return _reasonPhase();
      case _SwapPhase.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: CircularProgressIndicator(color: ZitlasTokens.primary)),
        );
      case _SwapPhase.result:
        return _resultPhase();
    }
  }

  Widget _reasonPhase() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Can't eat this?", style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
                  Text(widget.meal.mealName, style: const TextStyle(fontSize: 12, color: ZitlasTokens.textMuted)),
                ],
              ),
            ),
            IconButton(icon: const Icon(Icons.close, color: ZitlasTokens.textSecondary), onPressed: () => Navigator.of(context).pop()),
          ],
        ),
        const Text('Tell us why — we\'ll find something that works for you:', style: TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary)),
        const SizedBox(height: 12),
        ...kDietSwapReasons.map((r) => _reasonTile(icon: r.$1, title: r.$2, desc: r.$3, reason: r.$4)),
      ],
    );
  }

  Widget _reasonTile({required String icon, required String title, required String desc, required String reason}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: ZitlasTokens.bgCardLight,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _selectReason(reason),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: ZitlasTokens.borderSub)),
            child: Row(
              children: [
                Text(icon, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary)),
                      Text(desc, style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textMuted)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, size: 18, color: ZitlasTokens.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _resultPhase() {
    final result = _result!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Swap ${widget.meal.mealName}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
        const SizedBox(height: 4),
        Text('Current: ${widget.meal.foods.join(', ')}',
            style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary)),
        const SizedBox(height: 10),

        // Honesty banner — shown only when the engine had to widen its
        // nutrition band. Presenting a widened match as a true nutritional
        // peer would be misleading, so the athlete is told.
        if (result.relaxedMatch)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: ZitlasTokens.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('⚠ ${result.matchNote}',
                style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.primaryDark)),
          ),

        Text('${result.options.length} options — tap to choose',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: ZitlasTokens.textMuted)),
        const SizedBox(height: 8),

        for (var i = 0; i < result.options.length; i++)
          _OptionCard(
            option: result.options[i],
            rank: i + 1,
            selected: i == _selected,
            onTap: () => setState(() => _selected = i),
          ),

        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _tryAgain,
                style: OutlinedButton.styleFrom(
                  foregroundColor: ZitlasTokens.textSecondary,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Try Again'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: _accept,
                style: ElevatedButton.styleFrom(
                  backgroundColor: ZitlasTokens.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Accept'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// One engine-ranked option. Shows the macros, the data-derived reason,
/// availability and budget — everything the athlete needs to choose, straight
/// from the response.
class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.option,
    required this.rank,
    required this.selected,
    required this.onTap,
  });

  final SwapOption option;
  final int rank;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? ZitlasTokens.primary.withValues(alpha: 0.08) : ZitlasTokens.bgCardLight,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? ZitlasTokens.primary : ZitlasTokens.borderSub,
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (rank == 1)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Text('⭐', style: TextStyle(fontSize: 12)),
                      ),
                    Expanded(
                      child: Text(option.name,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
                    ),
                    if (selected)
                      const Icon(Icons.check_circle_rounded, size: 18, color: ZitlasTokens.primary),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${option.calories} kcal · ${option.proteinG}g P · '
                  '${option.carbsG}g C · ${option.fatG}g F',
                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: ZitlasTokens.textSecondary),
                ),
                const SizedBox(height: 4),
                Text(option.reason,
                    style: const TextStyle(fontSize: 11, height: 1.35, color: ZitlasTokens.textMuted)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _Tag(text: '📍 ${option.availability}'),
                    _Tag(text: '💰 ${option.budgetLevel}'),
                    if (option.highProtein) const _Tag(text: '💪 High protein'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: ZitlasTokens.bgCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: ZitlasTokens.borderSub),
        ),
        child: Text(text, style: const TextStyle(fontSize: 9.5, color: ZitlasTokens.textMuted)),
      );
}
