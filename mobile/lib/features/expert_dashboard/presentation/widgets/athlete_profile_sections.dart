import 'package:flutter/material.dart';

import '../../../../core/steps/step_history.dart';
import '../../../../core/theme/zitlas_tokens.dart';
import '../../../../core/util/json_coerce.dart';
import '../../../diet/models/diet_profile.dart';

/// The athlete's full picture, for the coach.
///
/// EVERY value here is read from a field that genuinely exists on
/// `users/{athleteId}`. Where the athlete hasn't provided something, the row
/// says "Not recorded" rather than showing a plausible number — a coach
/// programming against an invented body-fat percentage is worse off than one
/// who can see the field is empty and asks.
class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, required this.children, this.footer});

  final String icon;
  final String title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZitlasTokens.borderSub),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(icon, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 7),
              Text(
                title.toUpperCase(),
                style: const TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.7,
                  color: ZitlasTokens.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          ...children,
          if (footer != null) ...[
            const SizedBox(height: 7),
            Text(
              footer!,
              style: const TextStyle(fontSize: 10.5, height: 1.4, color: ZitlasTokens.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.emphasis = false});

  final String label;
  final String? value;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final missing = value == null || value!.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              missing ? 'Not recorded' : value!,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                fontWeight: emphasis ? FontWeight.w800 : FontWeight.w600,
                fontStyle: missing ? FontStyle.italic : FontStyle.normal,
                color: missing ? ZitlasTokens.textMuted : ZitlasTokens.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty || s == 'null' ? null : s;
}

String? _n(Object? v, {String suffix = '', int decimals = 0}) {
  final num? parsed = asNum(v);
  if (parsed == null) return null;
  final text = decimals == 0 ? parsed.round().toString() : parsed.toStringAsFixed(decimals);
  return '$text$suffix';
}

int? _ageFromDob(Object? dob) {
  final raw = _str(dob);
  if (raw == null) return null;
  final born = DateTime.tryParse(raw.length >= 10 ? raw.substring(0, 10) : raw);
  if (born == null) return null;
  final now = DateTime.now();
  var age = now.year - born.year;
  if (now.month < born.month || (now.month == born.month && now.day < born.day)) age--;
  return age > 0 && age < 130 ? age : null;
}

/// Photo, name, body metrics and goal progress.
class AthleteIdentityCard extends StatelessWidget {
  const AthleteIdentityCard({super.key, required this.data, required this.name});

  final Map<String, dynamic> data;
  final String name;

  @override
  Widget build(BuildContext context) {
    final info = (data['personalInfo'] as Map?)?.cast<String, dynamic>() ?? const {};
    final survey = (data['survey'] as Map?)?.cast<String, dynamic>() ?? const {};
    final goal = (data['goal'] as Map?)?.cast<String, dynamic>() ?? const {};
    final calc = (data['calculations'] as Map?)?.cast<String, dynamic>() ?? const {};

    final heightCm = asNum(info['heightCm']) ?? asNum(survey['height_cm']);
    final weightKg = asNum(info['weightKg']) ?? asNum(survey['weight_kg']);

    // Computed from height/weight rather than read from `calculations`, which
    // only refreshes when the athlete re-runs the Assessment and can be months
    // behind the weight they edited yesterday.
    num? bmi;
    if (heightCm != null && weightKg != null && heightCm > 50 && heightCm < 260) {
      bmi = weightKg / ((heightCm / 100) * (heightCm / 100));
    }

    final current = asNum(goal['current_value']);
    final target = asNum(goal['target_value']);
    final photo = _str(info['photo']) ?? _str(data['photo']);

    return _Section(
      icon: '👤',
      title: 'User',
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Avatar(name: name, photo: photo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _str(info['fullName']) ?? name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: ZitlasTokens.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (_ageFromDob(info['dob']) != null) '${_ageFromDob(info['dob'])} yrs',
                      if (_str(info['gender']) != null) _str(info['gender'])!,
                      if (_str(info['city']) != null) _str(info['city'])!,
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _Row('Height', _n(heightCm, suffix: ' cm')),
        _Row('Current weight', _n(weightKg, suffix: ' kg', decimals: 1)),
        _Row('Target weight', _n(target, suffix: ' kg', decimals: 1)),
        _Row('BMI', bmi == null ? null : '${bmi.toStringAsFixed(1)}'
            '${_str(calc['bmi_category']) != null ? " (${_str(calc['bmi_category'])})" : ""}'),
        // Body fat is not collected anywhere in ZITLAS today. Shown so the
        // coach knows it is a blank to fill in conversation, not a number the
        // app is hiding.
        _Row('Body fat %', _n(calc['body_fat_percent'] ?? survey['body_fat'])),
        _Row('Goal', _str(goal['type'])?.replaceAll('_', ' '), emphasis: true),
        if (current != null && target != null)
          _GoalProgress(current: current, target: target),
      ],
    );
  }
}

class _GoalProgress extends StatelessWidget {
  const _GoalProgress({required this.current, required this.target});

  final num current, target;

  @override
  Widget build(BuildContext context) {
    // Progress is only meaningful with a start point, which ZITLAS doesn't
    // store separately — so this shows the DISTANCE remaining, which is real,
    // rather than a percentage derived from an assumed baseline.
    final remaining = (target - current).abs();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: _Row(
        'To go',
        remaining == 0
            ? 'Target reached'
            : '${remaining.toStringAsFixed(1)} to target ($current → $target)',
        emphasis: true,
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, this.photo});

  final String name;
  final String? photo;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: ZitlasTokens.primary, shape: BoxShape.circle),
      child: Text(
        name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase(),
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.white),
      ),
    );
    final url = photo;
    if (url == null || !url.startsWith('http')) return fallback;
    return ClipOval(
      child: Image.network(
        url,
        width: 46,
        height: 46,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (context, child, p) => p == null ? child : fallback,
      ),
    );
  }
}

/// Diet type, preferred/avoided foods, allergies, budget, meal pattern.
class AthleteFoodPreferencesCard extends StatelessWidget {
  const AthleteFoodPreferencesCard({super.key, required this.profile});

  final DietProfile profile;

  @override
  Widget build(BuildContext context) {
    return _Section(
      icon: '🥗',
      title: 'Food preferences',
      footer: profile.isComplete
          ? null
          : 'This user has not finished their food profile — anything blank '
              'above is genuinely unknown, not hidden.',
      children: [
        _Row('Diet type', profile.dietPreference?.label, emphasis: true),
        _Row('Loves', profile.lovedFoods.isEmpty ? null : profile.lovedFoods.join(', ')),
        _Row('Dislikes', profile.dislikedFoods.isEmpty ? null : profile.dislikedFoods.join(', ')),
        _Row('Never eats', profile.neverEaten.isEmpty ? null : profile.neverEaten.join(', ')),
        _Row(
          'Allergies',
          profile.allergies.isEmpty ? null : profile.allergies.join(', '),
          emphasis: profile.allergies.isNotEmpty,
        ),
        _Row('Budget', profile.budget == null
            ? null
            : '${profile.budget!.label} — ${profile.budget!.blurb}'),
        _Row('Meals per day', '${profile.mealsPerDay}'),
        _Row('Who cooks', profile.preparer?.label),
      ],
    );
  }
}

/// Occupation, activity level, sleep.
class AthleteLifestyleCard extends StatelessWidget {
  const AthleteLifestyleCard({super.key, required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final survey = (data['survey'] as Map?)?.cast<String, dynamic>() ?? const {};
    final assessment = (data['assessment'] as Map?)?.cast<String, dynamic>() ?? const {};

    return _Section(
      icon: '🏠',
      title: 'Lifestyle',
      children: [
        _Row('Occupation', _str(survey['occupation'] ?? assessment['occupation'])),
        _Row(
          'Activity level',
          _str(survey['activity_level'] ?? assessment['activity_level'])?.replaceAll('_', ' '),
        ),
        _Row('Sleep', _n(survey['sleep_hours'] ?? assessment['sleep_hours'], suffix: ' hrs')),
      ],
    );
  }
}

/// Step goal, streaks — from the real activity record.
class AthleteFitnessCard extends StatelessWidget {
  const AthleteFitnessCard({
    super.key,
    required this.data,
    required this.history,
  });

  final Map<String, dynamic> data;

  /// The athlete's recorded days. Empty when the coach's device has no copy —
  /// step history is stored per-device and per-athlete, so a coach genuinely
  /// cannot see day-level detail here; goal and streaks come from the user doc.
  final StepHistory history;

  @override
  Widget build(BuildContext context) {
    final calc = (data['calculations'] as Map?)?.cast<String, dynamic>() ?? const {};
    return _Section(
      icon: '🏃',
      title: 'Fitness',
      children: [
        _Row(
          'Daily step goal',
          _n(data['dailyStepGoal'] ?? calc['daily_steps_goal'], suffix: ' steps'),
        ),
        _Row('Current streak', _n(data['currentStreak'], suffix: ' days')),
        _Row('Longest streak', _n(data['longestStreak'], suffix: ' days')),
      ],
    );
  }
}

/// BMI, BMR, TDEE, macro targets, SWOT, medical conditions.
class AthleteAssessmentCard extends StatelessWidget {
  const AthleteAssessmentCard({super.key, required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final calc = (data['calculations'] as Map?)?.cast<String, dynamic>() ?? const {};
    final swot = (data['swot'] as Map?)?.cast<String, dynamic>();
    final precautions = data['precautions'];

    final conditions = <String>[
      if (precautions is List)
        for (final p in precautions)
          if (_str(p) != null) _str(p)!,
      if (precautions is Map)
        for (final e in precautions.entries)
          if (e.value == true) e.key.toString().replaceAll('_', ' '),
    ];

    return _Section(
      icon: '📊',
      title: 'Assessment',
      children: [
        _Row('BMI', _n(calc['bmi'], decimals: 1)),
        _Row('BMR', _n(calc['bmr_kcal'], suffix: ' kcal')),
        _Row('TDEE', _n(calc['tdee_kcal'], suffix: ' kcal')),
        _Row(
          'Calorie target',
          _n(calc['weight_loss_calories_kcal'] ?? calc['calorie_target_kcal'], suffix: ' kcal'),
          emphasis: true,
        ),
        _Row(
          'Protein target',
          _n(calc['protein_target_g'] ?? calc['daily_protein_target_g'], suffix: ' g'),
          emphasis: true,
        ),
        _Row('Carbs target', _n(calc['carbs_g'], suffix: ' g')),
        _Row('Fat target', _n(calc['fat_g'], suffix: ' g')),
        _Row(
          'Medical',
          conditions.isEmpty ? null : conditions.join(', '),
          emphasis: conditions.isNotEmpty,
        ),
        if (swot != null) ...[
          const Divider(height: 18, color: ZitlasTokens.borderSub),
          _Row('Archetype', _str(swot['user_archetype'])),
          _Row('Summary', _str(swot['summary'])),
          _Row('Priority', _str(swot['priority_action'])),
        ],
      ],
    );
  }
}
