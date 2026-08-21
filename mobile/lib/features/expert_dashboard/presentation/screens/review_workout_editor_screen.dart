import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../workout/models/workout_day.dart';
import '../../../workout/models/workout_exercise.dart';
import '../../../workout/models/workout_plan_content.dart';
import '../../data/expert_repository.dart';
import '../widgets/exercise_editor_sheet.dart';

/// Native rebuild of `frontend/pages/experts/modify-workout.html` +
/// `modify-workout.js` — the expert's Training review editor. Loads the
/// `review_requests/{id}` doc's `planData` snapshot, lets the expert edit
/// each day's focus/duration and each exercise's sets/reps, and on save
/// writes `workoutChangeHistory` back onto the SAME doc — the exact field
/// `WorkoutController._maybeAutoSyncReview()` already reads to auto-apply
/// the change on the athlete's Training page (which has no explicit
/// "Accept" button by website design, unlike Diet).
class ReviewWorkoutEditorScreen extends StatefulWidget {
  const ReviewWorkoutEditorScreen({
    super.key,
    required this.reviewId,
    this.repository,
  });

  final String reviewId;

  /// Injectable so this screen can be pumped in a widget test — see the diet
  /// editor for why that seam exists.
  final ExpertRepository? repository;

  @override
  State<ReviewWorkoutEditorScreen> createState() => _ReviewWorkoutEditorScreenState();
}

class _ReviewWorkoutEditorScreenState extends State<ReviewWorkoutEditorScreen> {
  late final ExpertRepository _repository;
  bool _loading = true;
  bool _saving = false;
  Object? _error;
  Map<String, dynamic>? _raw;
  List<WorkoutDay> _days = const [];
  int _selectedDay = 0;
  final Map<int, WorkoutDay> _originalByDay = {};
  final Set<int> _editedDays = {};

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
      if (planData is Map && (planData['originalWorkoutPlan'] != null || planData['currentWorkoutPlan'] != null)) {
        planData = planData['currentWorkoutPlan'] ?? planData['originalWorkoutPlan'];
      }
      final content = planData is Map ? WorkoutPlanContent.fromMap(planData.cast<String, dynamic>()) : const WorkoutPlanContent();
      for (var i = 0; i < content.days.length; i++) {
        _originalByDay[i] = content.days[i];
      }
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
        title: const Text('Review Training Plan', style: TextStyle(color: ZitlasTokens.textPrimary, fontSize: 15, fontWeight: FontWeight.w800)),
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
                  ? const Center(child: Text('This user has no training plan on this request.', style: TextStyle(color: ZitlasTokens.textSecondary)))
                  : _body(),
    );
  }

  Widget _body() {
    final day = _days[_selectedDay];
    return Column(
      children: [
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
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(color: ZitlasTokens.bgCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: ZitlasTokens.borderSub)),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(day.theme, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
                          Text('${day.durationMinutes ?? '—'} min', style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textMuted)),
                        ],
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: _editDayHeader),
                  ],
                ),
              ),
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: day.exercises.length,
                onReorderItem: _reorderExercise,
                itemBuilder: (context, i) => _exerciseCard(
                  day,
                  i,
                  key: ValueKey('ex_${_selectedDay}_${i}_${day.exercises[i].name}'),
                ),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: _addExercise,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add Exercise'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _exerciseCard(WorkoutDay day, int exIdx, {Key? key}) {
    final ex = day.exercises[exIdx];
    // Only the fields the expert actually filled in are shown, so an
    // untouched exercise doesn't read as a wall of em-dashes.
    final detail = [
      if (ex.sets != null) '${ex.sets} sets',
      if (ex.repsOrDuration != null) ex.repsOrDuration!,
      if (ex.weight != null) ex.weight!,
      if (ex.restSeconds != null) 'rest ${ex.restSeconds}',
    ].join(' - ');
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 10),
      decoration: BoxDecoration(color: ZitlasTokens.bgCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: ZitlasTokens.borderSub)),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: exIdx,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.drag_indicator_rounded, size: 18, color: ZitlasTokens.textMuted),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ex.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary)),
                if (detail.isNotEmpty)
                  Text(detail, style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textMuted)),
                if (ex.tip != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      ex.tip!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: ZitlasTokens.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined, size: 16),
            onPressed: () => _editExercise(exIdx, ex),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline_rounded, size: 16, color: ZitlasTokens.danger),
            onPressed: () => _deleteExercise(exIdx),
          ),
        ],
      ),
    );
  }

  Future<void> _editDayHeader() async {
    final day = _days[_selectedDay];
    final focusCtrl = TextEditingController(text: day.theme);
    final durCtrl = TextEditingController(text: day.durationMinutes?.toString() ?? '');
    final ok = await _editDialog('Edit ${day.day}', [
      TextField(controller: focusCtrl, decoration: const InputDecoration(labelText: 'Focus')),
      const SizedBox(height: 10),
      TextField(controller: durCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Duration (minutes)')),
    ]);
    if (ok != true) return;
    setState(() {
      final updated = day.copyWith(focus: focusCtrl.text.trim(), durationMinutes: num.tryParse(durCtrl.text.trim()));
      _days = List.of(_days)..[_selectedDay] = updated;
      _editedDays.add(_selectedDay);
    });
  }

  /// Opens the FULL exercise editor — name, sets, reps/duration, weight,
  /// rest, and instructions.
  Future<void> _editExercise(int exIdx, WorkoutExercise ex) async {
    final updated = await showExerciseEditorSheet(context, exercise: ex);
    if (updated == null || !mounted) return;
    setState(() {
      final day = _days[_selectedDay];
      final exercises = List.of(day.exercises)..[exIdx] = updated;
      _days = List.of(_days)..[_selectedDay] = day.copyWith(exercises: exercises);
      _editedDays.add(_selectedDay);
    });
  }

  Future<void> _addExercise() async {
    final created = await showExerciseEditorSheet(
      context,
      exercise: const WorkoutExercise(name: ''),
      isNew: true,
    );
    if (created == null || !mounted) return;
    setState(() {
      final day = _days[_selectedDay];
      _days = List.of(_days)
        ..[_selectedDay] = day.copyWith(exercises: [...day.exercises, created]);
      _editedDays.add(_selectedDay);
    });
  }

  Future<void> _deleteExercise(int exIdx) async {
    final day = _days[_selectedDay];
    final name = day.exercises[exIdx].name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ZitlasTokens.bgCard,
        title: const Text('Remove exercise?'),
        content: Text('"$name" will be removed from ${day.day}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: ZitlasTokens.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      final exercises = List.of(day.exercises)..removeAt(exIdx);
      _days = List.of(_days)..[_selectedDay] = day.copyWith(exercises: exercises);
      _editedDays.add(_selectedDay);
    });
  }

  /// `onReorderItem` already accounts for the removed item, so newIndex must
  /// NOT be decremented here.
  void _reorderExercise(int oldIndex, int newIndex) {
    setState(() {
      final day = _days[_selectedDay];
      final exercises = List.of(day.exercises);
      exercises.insert(newIndex, exercises.removeAt(oldIndex));
      _days = List.of(_days)..[_selectedDay] = day.copyWith(exercises: exercises);
      _editedDays.add(_selectedDay);
    });
  }

  /// Copies this day's whole session onto another day. Days are otherwise
  /// fully independent — this is the only path that moves work between them,
  /// and it always asks first.
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
            Text('Copy ${_days[_selectedDay].day} to...',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
            const SizedBox(height: 4),
            const Text('This replaces the session on the day you pick.',
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
    setState(() {
      final source = _days[_selectedDay];
      _days = List.of(_days)
        ..[target] = _days[target].copyWith(
          focus: source.focus,
          durationMinutes: source.durationMinutes,
          exercises: List.of(source.exercises),
        );
      _editedDays.add(target);
      _selectedDay = target;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied to ${_days[_selectedDay].day}.')),
      );
    }
  }

  Future<bool?> _editDialog(String title, List<Widget> fields) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
        decoration: const BoxDecoration(color: ZitlasTokens.bgCard, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
            const SizedBox(height: 14),
            ...fields,
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: ZitlasTokens.primary),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save Change', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_editedDays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Make at least one change before sending.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final reviewedPlan = WorkoutPlanContent(days: _days).toMap();
      final now = DateTime.now().toIso8601String();
      final history = _editedDays.map((dayIdx) {
        final original = _originalByDay[dayIdx]!;
        final nw = _days[dayIdx];
        return {
          'dayIndex': dayIdx,
          'dayLabel': nw.day,
          'oldWorkout': original.toModificationSnapshot(),
          'newWorkout': nw.toModificationSnapshot(),
          'modifiedBy': 'Expert',
          'modifiedAt': now,
        };
      }).toList();

      await _repository.submitWorkoutReview(
        reviewId: widget.reviewId,
        reviewedWorkoutPlan: reviewedPlan,
        workoutChangeHistory: history,
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
