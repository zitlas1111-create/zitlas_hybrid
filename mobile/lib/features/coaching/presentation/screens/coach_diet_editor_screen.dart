import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../diet/models/diet_profile.dart';
import '../../../expert_dashboard/data/food_search_repository.dart';
import '../../../expert_dashboard/presentation/widgets/food_search_sheet.dart';
import '../../data/coaching_plan_repository.dart';
import '../../models/coach_diet_plan.dart';
import '../../models/plan_compliance.dart';
import '../../models/protein_variety.dart';
import '../widgets/coach_option_editor_sheet.dart';
import '../widgets/compliance_banner.dart';
import '../widgets/protein_variety_panel.dart';

/// The coach's diet editor — the write half of the coaching workspace.
///
/// Edits a LOCAL DRAFT and publishes on Save. The athlete's screen holds a live
/// listener, so a half-finished week would otherwise stream to them keystroke
/// by keystroke; a draft means the coach controls exactly when the athlete
/// sees anything.
///
/// Reuses `showFoodSearchSheet` against the real 4,520-food dataset — the coach
/// cannot type a food that doesn't exist into the plan through the Add path,
/// which is what keeps the athlete's plan aligned with what the engine scores.
class CoachDietEditorScreen extends StatefulWidget {
  const CoachDietEditorScreen({
    super.key,
    required this.athleteId,
    required this.athleteName,
    required this.coachId,
    required this.coachName,
    required this.planType,
    required this.initialPlan,
    required this.athleteProfile,
    this.athletePlanId,
    this.repository,
    this.foodRepository,
  });

  final String athleteId;
  final String athleteName;
  final String coachId;
  final String coachName;
  final String planType;
  final CoachDietPlan initialPlan;

  /// The athlete's own recorded preferences — never hidden from the coach
  /// (Step 6). Drives every compliance flag on this screen.
  final DietProfile athleteProfile;

  final String? athletePlanId;
  final CoachingPlanRepository? repository;
  final FoodSearchRepository? foodRepository;

  @override
  State<CoachDietEditorScreen> createState() => _CoachDietEditorScreenState();
}

class _CoachDietEditorScreenState extends State<CoachDietEditorScreen> {
  late final CoachingPlanRepository _repo = widget.repository ?? CoachingPlanRepository();
  late final FoodSearchRepository _foods = widget.foodRepository ?? FoodSearchRepository();

  late CoachDietPlan _draft = _seed();
  int _dayIndex = 0;
  bool _dirty = false;
  bool _saving = false;

  /// Budget/diet/allergen tags for foods added through search, keyed by lower
  /// case name. The dataset knows these; a plan document does not carry them,
  /// so they are collected as the coach picks and used for compliance.
  final _budgetByFood = <String, String>{};
  final _dietByFood = <String, List<String>>{};
  final _allergensByFood = <String, List<String>>{};

  CoachDietPlan _seed() {
    // An empty coach plan starts as a blank week rather than nothing, so the
    // coach has meal slots to fill instead of an empty screen.
    return widget.initialPlan.hasDays ? widget.initialPlan : CoachDietPlan.emptyWeek();
  }

  CoachDietDay get _day => _draft.days[_dayIndex];

  void _mutateDay(CoachDietDay Function(CoachDietDay) change) {
    setState(() {
      final days = [..._draft.days];
      days[_dayIndex] = change(days[_dayIndex]);
      _draft = _draft.copyWith(days: days);
      _dirty = true;
    });
  }

  void _mutateMeal(int mealIndex, CoachMeal Function(CoachMeal) change) {
    _mutateDay((day) {
      final meals = [...day.meals];
      meals[mealIndex] = change(meals[mealIndex]);
      return day.copyWith(meals: meals);
    });
  }

  // ── Meal-level actions (Step 2) ─────────────────────────────────────────

  Future<void> _addMeal() async {
    final name = await _askText(title: 'New meal', hint: 'e.g. Pre-workout');
    if (name == null || name.trim().isEmpty) return;
    _mutateDay((day) => day.copyWith(meals: [
          ...day.meals,
          // Time-based id so it can't collide with an existing meal's — the
          // athlete's selections are keyed on it.
          CoachMeal(id: 'meal_${DateTime.now().millisecondsSinceEpoch}', name: name.trim()),
        ]));
  }

  void _deleteMeal(int index) {
    final removed = _day.meals[index];
    _mutateDay((day) => day.copyWith(meals: [...day.meals]..removeAt(index)));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('${removed.name} removed'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _mutateDay((day) {
            final meals = [...day.meals];
            meals.insert(index.clamp(0, meals.length), removed);
            return day.copyWith(meals: meals);
          }),
        ),
      ));
  }

  void _duplicateMeal(int index) {
    final source = _day.meals[index];
    _mutateDay((day) {
      final meals = [...day.meals];
      meals.insert(
        index + 1,
        CoachMeal(
          id: 'meal_${DateTime.now().millisecondsSinceEpoch}',
          name: '${source.name} (copy)',
          time: source.time,
          options: source.options,
        ),
      );
      return day.copyWith(meals: meals);
    });
  }

  void _moveMeal(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _day.meals.length) return;
    _mutateDay((day) {
      final meals = [...day.meals];
      final moved = meals.removeAt(index);
      meals.insert(target, moved);
      return day.copyWith(meals: meals);
    });
  }

  Future<void> _renameMeal(int index) async {
    final name = await _askText(title: 'Meal name', initial: _day.meals[index].name);
    if (name == null || name.trim().isEmpty) return;
    _mutateMeal(index, (m) => m.copyWith(name: name.trim()));
  }

  Future<void> _editTime(int index) async {
    final current = _day.meals[index].time;
    final parsed = _parseTime(current);
    final picked = await showTimePicker(
      context: context,
      initialTime: parsed ?? const TimeOfDay(hour: 8, minute: 0),
    );
    if (picked == null || !mounted) return;
    final label = picked.format(context);
    _mutateMeal(index, (m) => m.copyWith(time: label));
  }

  /// Copies the whole day onto another — a coach building a week rarely wants
  /// seven genuinely different days.
  Future<void> _copyDayTo() async {
    final target = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: ZitlasTokens.bgCard,
        title: Text('Copy ${_day.day} to…'),
        children: [
          for (var i = 0; i < _draft.days.length; i++)
            if (i != _dayIndex)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, i),
                child: Text(_draft.days[i].day),
              ),
        ],
      ),
    );
    if (target == null) return;
    setState(() {
      final days = [..._draft.days];
      days[target] = days[target].copyWith(meals: _day.meals);
      _draft = _draft.copyWith(days: days);
      _dirty = true;
    });
  }

  // ── Option-level actions (Steps 2, 3) ───────────────────────────────────

  /// Adds a food from the REAL dataset, and flags it against the athlete's
  /// profile immediately — before it reaches their plan.
  Future<void> _addOptionFromSearch(int mealIndex) async {
    final meal = _day.meals[mealIndex];
    final result = await showFoodSearchSheet(
      context,
      title: 'Add to ${meal.name}',
      repository: _foods,
    );
    if (result == null || !mounted) return;

    final key = result.name.toLowerCase();
    if (result.budgetCategory != null) _budgetByFood[key] = result.budgetCategory!;
    _dietByFood[key] = result.dietSuitable;
    _allergensByFood[key] = result.allergens;

    _mutateMeal(mealIndex, (m) => m.copyWith(options: [
          ...m.options,
          CoachMealOption(
            name: result.name,
            calories: result.calories,
            protein: result.protein,
            carbs: result.carbs,
            fat: result.fat,
          ),
        ]));

    final flags = checkFood(
      foodName: result.name,
      profile: widget.athleteProfile,
      dietSuitable: result.dietSuitable,
      allergens: result.allergens,
      budgetCategory: result.budgetCategory,
    );
    if (flags.isNotEmpty && mounted) _warnAboutFood(flags);
  }

  void _warnAboutFood(List<ComplianceFlag> flags) {
    final worst = flags.firstWhere(
      (f) => f.issue.isSevere,
      orElse: () => flags.first,
    );
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        backgroundColor: worst.issue.isSevere ? ZitlasTokens.danger : null,
        duration: const Duration(seconds: 5),
        content: Text('${worst.issue.icon} ${worst.detail} — added anyway, '
            'remove it if that was not deliberate.'),
      ));
  }

  Future<void> _editOption(int mealIndex, int optionIndex) async {
    final meal = _day.meals[mealIndex];
    final edited = await showCoachOptionEditorSheet(
      context,
      option: meal.options[optionIndex],
      mealName: meal.name,
    );
    if (edited == null) return;
    _mutateMeal(mealIndex, (m) {
      final options = [...m.options];
      options[optionIndex] = edited;
      return m.copyWith(options: options);
    });
  }

  Future<void> _replaceOption(int mealIndex, int optionIndex) async {
    final meal = _day.meals[mealIndex];
    final result = await showFoodSearchSheet(
      context,
      title: 'Replace ${meal.options[optionIndex].name}',
      repository: _foods,
      initialQuery: '',
    );
    if (result == null || !mounted) return;

    final key = result.name.toLowerCase();
    if (result.budgetCategory != null) _budgetByFood[key] = result.budgetCategory!;
    _dietByFood[key] = result.dietSuitable;
    _allergensByFood[key] = result.allergens;

    _mutateMeal(mealIndex, (m) {
      final options = [...m.options];
      options[optionIndex] = CoachMealOption(
        name: result.name,
        calories: result.calories,
        protein: result.protein,
        carbs: result.carbs,
        fat: result.fat,
        // The coach's note survives a food swap — it is usually about the
        // athlete ("keep it light before training"), not the dish.
        notes: options[optionIndex].notes,
      );
      return m.copyWith(options: options);
    });
  }

  void _deleteOption(int mealIndex, int optionIndex) {
    _mutateMeal(mealIndex, (m) {
      final options = [...m.options]..removeAt(optionIndex);
      return m.copyWith(options: options);
    });
  }

  // ── Save (Step 9) ───────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _repo.saveDiet(
        athleteId: widget.athleteId,
        athleteName: widget.athleteName,
        coachId: widget.coachId,
        coachName: widget.coachName,
        planType: widget.planType,
        diet: _draft,
        athletePlanId: widget.athletePlanId,
      );
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _saving = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('✅ Published to ${widget.athleteName}'),
        ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('Could not publish: ${_friendly(e)}'),
          action: SnackBarAction(label: 'Retry', onPressed: _save),
        ));
    }
  }

  static String _friendly(Object e) {
    final raw = e.toString().replaceFirst('Exception: ', '');
    if (raw.toLowerCase().contains('permission')) {
      return 'you are no longer this user\'s active coach.';
    }
    return 'please check your connection and try again.';
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ZitlasTokens.bgCard,
        title: const Text('Discard unpublished changes?'),
        content: Text(
          '${widget.athleteName} has not seen these edits yet — they are only '
          'sent when you publish.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard', style: TextStyle(color: ZitlasTokens.danger)),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final compliance = checkPlan(
      plan: _draft,
      profile: widget.athleteProfile,
      budgetByFood: _budgetByFood,
      dietSuitableByFood: _dietByFood,
      allergensByFood: _allergensByFood,
    );
    final variety = analyseProteinVariety(_draft);

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Captured before the await so the pop doesn't reach for a context
        // that may no longer be mounted by the time the dialog closes.
        final navigator = Navigator.of(context);
        if (await _confirmDiscard()) navigator.pop();
      },
      child: Scaffold(
        backgroundColor: ZitlasTokens.bgStart,
        appBar: AppBar(
          backgroundColor: ZitlasTokens.bgCard,
          elevation: 0,
          iconTheme: const IconThemeData(color: ZitlasTokens.textPrimary),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Diet Plan',
                style: TextStyle(
                  color: ZitlasTokens.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                widget.athleteName,
                style: const TextStyle(color: ZitlasTokens.textSecondary, fontSize: 11.5),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: _dirty && !_saving ? _save : null,
              child: Text(
                _saving ? 'Publishing…' : 'Publish',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: _dirty && !_saving
                      ? ZitlasTokens.primary
                      : ZitlasTokens.textMuted,
                ),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            // The athlete's own preferences, never hidden (Step 6).
            AthletePreferenceStrip(profile: widget.athleteProfile),
            const SizedBox(height: 12),
            if (!compliance.isClean) ...[
              ComplianceBanner(report: compliance),
              const SizedBox(height: 12),
            ],
            ProteinVarietyPanel(report: variety),
            const SizedBox(height: 14),
            _DayTabs(
              days: _draft.days,
              selected: _dayIndex,
              onSelect: (i) => setState(() => _dayIndex = i),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  _day.day,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: ZitlasTokens.textPrimary,
                  ),
                ),
                const Spacer(),
                if (_day.representativeCalories > 0)
                  Text(
                    '~${_day.representativeCalories.round()} kcal · '
                    '${_day.representativeProtein.round()}g P',
                    style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textMuted),
                  ),
                IconButton(
                  tooltip: 'Copy this day to another',
                  onPressed: _copyDayTo,
                  icon: const Icon(Icons.copy_all_rounded, size: 19),
                  color: ZitlasTokens.textSecondary,
                ),
              ],
            ),
            for (var i = 0; i < _day.meals.length; i++)
              _MealEditorCard(
                meal: _day.meals[i],
                profile: widget.athleteProfile,
                budgetByFood: _budgetByFood,
                dietByFood: _dietByFood,
                allergensByFood: _allergensByFood,
                canMoveUp: i > 0,
                canMoveDown: i < _day.meals.length - 1,
                onRename: () => _renameMeal(i),
                onEditTime: () => _editTime(i),
                onDelete: () => _deleteMeal(i),
                onDuplicate: () => _duplicateMeal(i),
                onMoveUp: () => _moveMeal(i, -1),
                onMoveDown: () => _moveMeal(i, 1),
                onAddFood: () => _addOptionFromSearch(i),
                onEditOption: (o) => _editOption(i, o),
                onReplaceOption: (o) => _replaceOption(i, o),
                onDeleteOption: (o) => _deleteOption(i, o),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _addMeal,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add a meal'),
              style: OutlinedButton.styleFrom(
                foregroundColor: ZitlasTokens.primary,
                side: const BorderSide(color: ZitlasTokens.borderSub),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _askText({
    required String title,
    String? initial,
    String? hint,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ZitlasTokens.bgCard,
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  static TimeOfDay? _parseTime(String? raw) {
    if (raw == null) return null;
    final match = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(raw);
    if (match == null) return null;
    var hour = int.tryParse(match.group(1)!) ?? 8;
    final minute = int.tryParse(match.group(2)!) ?? 0;
    final lower = raw.toLowerCase();
    if (lower.contains('pm') && hour < 12) hour += 12;
    if (lower.contains('am') && hour == 12) hour = 0;
    return TimeOfDay(hour: hour % 24, minute: minute % 60);
  }
}

class _DayTabs extends StatelessWidget {
  const _DayTabs({required this.days, required this.selected, required this.onSelect});

  final List<CoachDietDay> days;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: days.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final active = i == selected;
          final filled = days[i].meals.any((m) => m.hasOptions);
          return GestureDetector(
            onTap: () => onSelect(i),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 15),
              decoration: BoxDecoration(
                color: active ? ZitlasTokens.primary : ZitlasTokens.bgCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: active ? ZitlasTokens.primary : ZitlasTokens.borderSub,
                ),
              ),
              child: Row(
                children: [
                  Text(
                    days[i].day.substring(0, 3),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: active ? Colors.white : ZitlasTokens.textPrimary,
                    ),
                  ),
                  // A dot marks days that actually have food in them, so a
                  // coach can see at a glance what's left to build.
                  if (filled) ...[
                    const SizedBox(width: 5),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active ? Colors.white : ZitlasTokens.success,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MealEditorCard extends StatelessWidget {
  const _MealEditorCard({
    required this.meal,
    required this.profile,
    required this.budgetByFood,
    required this.dietByFood,
    required this.allergensByFood,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onRename,
    required this.onEditTime,
    required this.onDelete,
    required this.onDuplicate,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onAddFood,
    required this.onEditOption,
    required this.onReplaceOption,
    required this.onDeleteOption,
  });

  final CoachMeal meal;
  final DietProfile profile;
  final Map<String, String> budgetByFood;
  final Map<String, List<String>> dietByFood;
  final Map<String, List<String>> allergensByFood;
  final bool canMoveUp, canMoveDown;
  final VoidCallback onRename, onEditTime, onDelete, onDuplicate, onMoveUp, onMoveDown, onAddFood;
  final void Function(int) onEditOption, onReplaceOption, onDeleteOption;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ZitlasTokens.borderSub),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: onRename,
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            meal.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              color: ZitlasTokens.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        const Icon(Icons.edit_rounded, size: 13, color: ZitlasTokens.textMuted),
                      ],
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: onEditTime,
                  icon: const Icon(Icons.schedule_rounded, size: 15),
                  label: Text(meal.time ?? 'Set time'),
                  style: TextButton.styleFrom(
                    foregroundColor: ZitlasTokens.textSecondary,
                    textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded, size: 18, color: ZitlasTokens.textMuted),
                  onSelected: (v) => switch (v) {
                    'duplicate' => onDuplicate(),
                    'up' => onMoveUp(),
                    'down' => onMoveDown(),
                    _ => onDelete(),
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'duplicate', child: Text('Duplicate meal')),
                    if (canMoveUp) const PopupMenuItem(value: 'up', child: Text('Move up')),
                    if (canMoveDown) const PopupMenuItem(value: 'down', child: Text('Move down')),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete meal', style: TextStyle(color: ZitlasTokens.danger)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (meal.options.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 2, 14, 10),
              child: Text(
                'No food yet — add one from the ZITLAS database.',
                style: TextStyle(fontSize: 11.5, color: ZitlasTokens.textMuted),
              ),
            )
          else
            for (var i = 0; i < meal.options.length; i++)
              _OptionRow(
                option: meal.options[i],
                flags: checkFood(
                  foodName: meal.options[i].name,
                  profile: profile,
                  dietSuitable: dietByFood[meal.options[i].name.toLowerCase()] ?? const [],
                  allergens: allergensByFood[meal.options[i].name.toLowerCase()] ?? const [],
                  budgetCategory: budgetByFood[meal.options[i].name.toLowerCase()],
                ),
                onEdit: () => onEditOption(i),
                onReplace: () => onReplaceOption(i),
                onDelete: () => onDeleteOption(i),
              ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: TextButton.icon(
              onPressed: onAddFood,
              icon: const Icon(Icons.add_rounded, size: 17),
              label: const Text('Add food'),
              style: TextButton.styleFrom(
                foregroundColor: ZitlasTokens.primary,
                textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.flags,
    required this.onEdit,
    required this.onReplace,
    required this.onDelete,
  });

  final CoachMealOption option;
  final List<ComplianceFlag> flags;
  final VoidCallback onEdit, onReplace, onDelete;

  @override
  Widget build(BuildContext context) {
    final macros = <String>[
      if (option.calories != null) '${option.calories!.round()} kcal',
      if (option.protein != null) 'P ${option.protein!.round()}g',
      if (option.carbs != null) 'C ${option.carbs!.round()}g',
      if (option.fat != null) 'F ${option.fat!.round()}g',
    ].join(' · ');

    final severe = flags.any((f) => f.issue.isSevere);

    return InkWell(
      onTap: onEdit,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 7),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: severe
              ? ZitlasTokens.danger.withValues(alpha: 0.07)
              : ZitlasTokens.bgCardLight,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: severe ? ZitlasTokens.danger.withValues(alpha: 0.4) : ZitlasTokens.borderSub,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.name,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: ZitlasTokens.textPrimary,
                    ),
                  ),
                  if (macros.isNotEmpty)
                    Text(
                      macros,
                      style: const TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted),
                    ),
                  if (option.notes != null)
                    Text(
                      option.notes!,
                      style: const TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: ZitlasTokens.textSecondary,
                      ),
                    ),
                  for (final f in flags)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${f.issue.icon} ${f.detail}',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: f.issue.isSevere
                              ? ZitlasTokens.danger
                              : ZitlasTokens.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Replace with another food',
              onPressed: onReplace,
              icon: const Icon(Icons.swap_horiz_rounded, size: 17),
              color: ZitlasTokens.textSecondary,
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: onDelete,
              icon: const Icon(Icons.close_rounded, size: 16),
              color: ZitlasTokens.textMuted,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}
