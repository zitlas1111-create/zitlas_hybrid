import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../diet/models/diet_day.dart';
import '../../../diet/models/diet_meal.dart';
import '../../../diet/models/diet_plan_content.dart';
import '../../data/expert_repository.dart';
import '../../data/food_search_repository.dart';
import '../widgets/meal_editor_sheet.dart';

/// Native rebuild of `frontend/pages/experts/modify-diet.html` +
/// `modify-diet.js` — the expert's Diet review editor. Loads the
/// `review_requests/{id}` doc's `planData` snapshot, lets the expert edit
/// each meal's foods/calories/protein, and on save writes
/// `reviewedDietPlan` + `mealChangeHistory` back onto the SAME doc — the
/// exact shape `DietController.acceptExpertReview()` already consumes on
/// the athlete side (CLAUDE.md "Diet Modification System — the
/// authoritative pattern"). No new schema.
class ReviewDietEditorScreen extends StatefulWidget {
  const ReviewDietEditorScreen({
    super.key,
    required this.reviewId,
    this.repository,
    this.foodRepository,
  });

  final String reviewId;

  /// Injectable so this screen can be pumped in a widget test. Without a seam
  /// here the screen could only ever be verified by hand on a device, which
  /// is exactly how "the editor is wired" went unproven.
  final ExpertRepository? repository;
  final FoodSearchRepository? foodRepository;

  @override
  State<ReviewDietEditorScreen> createState() => _ReviewDietEditorScreenState();
}

class _ReviewDietEditorScreenState extends State<ReviewDietEditorScreen> {
  late final ExpertRepository _repository;
  bool _loading = true;
  bool _saving = false;
  Object? _error;
  Map<String, dynamic>? _raw;
  List<DietDay> _days = const [];
  int _selectedDay = 0;
  final Map<String, MapEntry<DietMeal, DietMeal>> _edits = {}; // key = "dayIdx.mealKey" -> (old, new)

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ??
        ExpertRepository(firestore: FirebaseFirestore.instance, auth: FirebaseAuth.instance);
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await _repository.fetchReviewRaw(widget.reviewId);
      if (raw == null) {
        setState(() {
          _error = 'not_found';
          _loading = false;
        });
        return;
      }
      var planData = raw['planData'];
      if (planData is Map && (planData['originalDietPlan'] != null || planData['currentDietPlan'] != null)) {
        planData = planData['currentDietPlan'] ?? planData['originalDietPlan'];
      }
      final content = planData is Map ? DietPlanContent.fromMap(planData.cast<String, dynamic>()) : const DietPlanContent();
      setState(() {
        _raw = raw;
        _days = content.days;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZitlasTokens.bgStart,
      appBar: AppBar(
        backgroundColor: ZitlasTokens.bgCard,
        title: const Text('Review Diet Plan', style: TextStyle(color: ZitlasTokens.textPrimary, fontSize: 15, fontWeight: FontWeight.w800)),
        actions: [
          if (!_loading && _error == null)
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save & Send', style: TextStyle(fontWeight: FontWeight.w800, color: ZitlasTokens.primaryDark)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: ZitlasTokens.primary))
          : _error != null
              ? Center(
                  child: Text(
                    _error == 'not_found' ? 'This review request no longer exists.' : 'Could not load this review.',
                    style: const TextStyle(color: ZitlasTokens.textSecondary),
                  ),
                )
              : _days.isEmpty
                  ? const Center(child: Text('This user has no diet plan on this request.', style: TextStyle(color: ZitlasTokens.textSecondary)))
                  : _body(),
    );
  }

  Widget _body() {
    return Column(
      children: [
        // Day tabs + Copy Day. Each day is edited independently; Copy Day is
        // the only path that moves edits between days, and it always asks.
        Row(
          children: [
            Expanded(
              child: SizedBox(
          height: 46,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            scrollDirection: Axis.horizontal,
            itemCount: _days.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final selected = i == _selectedDay;
              return ChoiceChip(
                label: Text(_days[i].day, style: const TextStyle(fontSize: 12)),
                selected: selected,
                onSelected: (_) => setState(() => _selectedDay = i),
                selectedColor: ZitlasTokens.primary,
                labelStyle: TextStyle(color: selected ? Colors.white : ZitlasTokens.textSecondary),
              );
            },
          ),
        ),
            ),
            IconButton(
              tooltip: 'Copy this day to another',
              icon: const Icon(Icons.copy_all_rounded, size: 19, color: ZitlasTokens.textSecondary),
              onPressed: _copyDay,
            ),
            const SizedBox(width: 6),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: _days[_selectedDay].meals.map((meal) => _mealCard(_selectedDay, meal)).toList(),
          ),
        ),
      ],
    );
  }

  Widget _mealCard(int dayIdx, DietMeal meal) {
    final key = '$dayIdx.${meal.mealKey}';
    final edited = _edits.containsKey(key);
    final display = edited ? _edits[key]!.value : meal;

    // The WHOLE card opens the editor, not just a small pencil icon — tapping
    // the thing you want to change is the obvious gesture, and an icon-only
    // affordance reads as a view-only list.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _editMeal(dayIdx, meal, display),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: edited ? ZitlasTokens.primary : ZitlasTokens.borderSub,
                width: edited ? 1.6 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(display.mealName, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
                    ),
                    if (edited)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(color: ZitlasTokens.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                        child: const Text('Edited', style: TextStyle(fontSize: 10, color: ZitlasTokens.primaryDark, fontWeight: FontWeight.w700)),
                      ),
                    // A labelled control, so it's unmistakable that this
                    // screen edits rather than displays.
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: ZitlasTokens.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.edit_outlined, size: 13, color: ZitlasTokens.primaryDark),
                          SizedBox(width: 4),
                          Text('Edit', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: ZitlasTokens.primaryDark)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(display.foods.join(', '), style: const TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary)),
                const SizedBox(height: 4),
                Text(
                  '${display.calories ?? '—'} kcal · ${display.proteinG ?? '—'}g protein',
                  style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Opens the FULL meal editor (every food item, quantity, unit, and the
  /// meal's calories/protein/carbs/fat/notes) and records the diff.
  Future<void> _editMeal(int dayIdx, DietMeal original, DietMeal current) async {
    final updated = await showMealEditorSheet(
      context,
      meal: current,
      foodRepository: widget.foodRepository,
    );
    if (updated == null || !mounted) return;
    setState(() {
      // The diff is always kept against the ORIGINAL meal, so re-editing the
      // same meal twice still reports one change from what the athlete had —
      // not a change from the expert's own previous draft.
      _edits['$dayIdx.${original.mealKey}'] = MapEntry(original, updated);
      final day = _days[dayIdx];
      final meals = day.meals.map((m) => m.mealKey == original.mealKey ? updated : m).toList();
      _days = List.of(_days)..[dayIdx] = day.copyWithMeals(meals);
    });
  }

  /// Copies every meal from one day onto another. Days are otherwise fully
  /// independent — this is the only way one day's edits reach another, and it
  /// is always explicit.
  Future<void> _copyDay() async {
    final targets = <int>[for (var i = 0; i < _days.length; i++) if (i != _selectedDay) i];
    if (targets.isEmpty) return;
    final target = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: ZitlasTokens.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Copy ${_days[_selectedDay].day} to…',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
            const SizedBox(height: 4),
            const Text('This replaces every meal on the day you pick.',
                style: TextStyle(fontSize: 12, color: ZitlasTokens.textMuted)),
            const SizedBox(height: 12),
            for (final i in targets)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(_days[i].day, style: const TextStyle(fontSize: 13.5)),
                trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                onTap: () => Navigator.pop(ctx, i),
              ),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;

    final source = _days[_selectedDay];
    setState(() {
      final copied = source.meals
          .map((m) => m.copyWith(
                edited: true,
                modifiedBy: 'Expert',
                modifiedAt: DateTime.now().toIso8601String(),
              ))
          .toList();
      final targetDay = _days[target];
      // Diff each copied meal against what that day ORIGINALLY had, so the
      // athlete's change history describes the real before/after.
      for (final meal in copied) {
        final before = targetDay.meals.firstWhere(
          (m) => m.mealKey == meal.mealKey,
          orElse: () => meal,
        );
        _edits['$target.${meal.mealKey}'] = MapEntry(before, meal);
      }
      _days = List.of(_days)..[target] = targetDay.copyWithMeals(copied);
      _selectedDay = target;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied to ${_days[_selectedDay].day}.')),
      );
    }
  }

  Future<void> _save() async {
    // Re-entry guard independent of the button's disabled state: `_saving`
    // only reaches the button on the next frame, so a fast double-tap can
    // otherwise start two saves — two writes and two "sent" snackbars.
    if (_saving) return;
    if (_edits.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Make at least one change before sending.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final reviewedPlan = DietPlanContent(days: _days).toMap();
      final now = DateTime.now().toIso8601String();
      final history = _edits.entries.map((e) {
        final dayIdx = int.parse(e.key.split('.').first);
        final old = e.value.key;
        final nw = e.value.value;
        return {
          'dayIndex': dayIdx,
          'mealName': nw.mealName,
          'dayLabel': _days[dayIdx].day,
          'oldFoods': old.foods,
          'newFoods': nw.foods,
          'oldCalories': old.calories,
          'newCalories': nw.calories,
          'oldProtein': old.proteinG,
          'newProtein': nw.proteinG,
          'modifiedBy': 'Expert',
          'modifiedAt': now,
        };
      }).toList();

      await _repository.submitDietReview(
        reviewId: widget.reviewId,
        reviewedDietPlan: reviewedPlan,
        mealChangeHistory: history,
        expertId: (_raw?['expertId'] as String?) ?? '',
        expertName: (_raw?['expertName'] as String?) ?? 'Expert',
        athleteId: _raw?['userId'] as String?,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Review sent to user.')));
      // Pop the SAME navigator this screen was pushed onto
      // (`Navigator.push` in ExpertDashboardScreen._openReviewEditor), and
      // return to the Expert Dashboard underneath. Deliberately a plain pop:
      // the expert must never be pushed or redirected into Chat after
      // completing a review.
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save — please try again.')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
