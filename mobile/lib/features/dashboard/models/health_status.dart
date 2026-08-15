/// Models + the deterministic adjustment engine for the "❤️ How are you
/// feeling today?" card, ported field-for-field and rule-for-rule from
/// `frontend/assets/js/health-status.js`.
///
/// The engine is deliberately rule-based (no LLM call), exactly like the
/// website: the same report must always produce the same adjustment.
library;

class HealthStatusOption {
  const HealthStatusOption(this.key, this.label);
  final String key;
  final String label;
}

/// `STATUSES` (health-status.js:28-36) — order and labels are exact.
const healthStatuses = <HealthStatusOption>[
  HealthStatusOption('great', '😊 Feeling Great'),
  HealthStatusOption('unwell', '😐 Slightly Unwell'),
  HealthStatusOption('sick', '🤒 Sick Today'),
  HealthStatusOption('injured', '🤕 Injured'),
  HealthStatusOption('poor_sleep', '😴 Poor Sleep'),
  HealthStatusOption('stress', '😰 High Stress'),
  HealthStatusOption('other', '➕ Other'),
];

/// `SYMPTOMS` (health-status.js:37-39).
const healthSymptoms = <String>[
  'Fever', 'Cold', 'Cough', 'Headache', 'Vomiting', 'Diarrhea',
  'Food Poisoning', 'Sore Throat', 'Stomach Pain', 'Weakness', 'Fatigue',
  'Body Pain', 'Chest Pain', 'Difficulty Breathing', 'Other',
];

/// `BODY_PARTS` (health-status.js:40-41).
const healthBodyParts = <String>[
  'Neck', 'Shoulder', 'Chest', 'Back', 'Lower Back', 'Elbow',
  'Wrist', 'Hip', 'Knee', 'Ankle', 'Foot',
];

String healthStatusLabel(String key) =>
    healthStatuses.firstWhere((s) => s.key == key, orElse: () => HealthStatusOption(key, key)).label;

const healthStatusIcons = <String, String>{
  'great': '😊', 'unwell': '😐', 'sick': '🤒', 'injured': '🤕',
  'poor_sleep': '😴', 'stress': '😰', 'other': '➕',
};

/// The in-progress report the bottom sheet builds — `draft` on the website.
class HealthReport {
  // `symptoms`/`bodyParts` default to a FRESH mutable list per instance,
  // never a shared `const []` — the bottom sheet's chip toggles mutate
  // these in place (`_draft.symptoms.add(v)`/`.remove(v)`), and a `const []`
  // literal is unmodifiable in Dart. Defaulting to it here was the ROOT
  // CAUSE of the reported "follow-up options cannot reliably be selected"
  // bug: every tap on a symptom or body-part chip threw
  // `Unsupported operation: Cannot add to an unmodifiable list`, which
  // reads to the user as "nothing happened" once Flutter's error zone
  // swallows it, not as a visible crash.
  HealthReport({
    required this.status,
    List<String>? symptoms,
    List<String>? bodyParts,
    this.severity,
    this.painLevel = 5,
    this.sleepHours = 6,
    this.stressLevel = 7,
    this.note = '',
  }) : symptoms = symptoms ?? <String>[],
       bodyParts = bodyParts ?? <String>[];

  final String status;
  List<String> symptoms;
  List<String> bodyParts;

  /// 'mild' | 'moderate' | 'severe'
  String? severity;
  int painLevel;
  double sleepHours;
  int stressLevel;
  String note;
}

class HealthPlanBlock {
  const HealthPlanBlock({required this.title, required this.items, this.mode, this.meals = const []});

  /// `workout.title` or `diet.focus`.
  final String title;
  final List<String> items;

  /// 'none' | 'rest' | 'reduced' | 'mobility' | 'modified' (workout only).
  final String? mode;

  /// The ACTUAL replacement content for today — a full list of meal maps
  /// (diet, `recoveryMeals()`-shaped: `meal_name`/`time`/`foods`/`purpose`/
  /// `emoji`/`color`/`_recovery`, directly `DietMeal.fromMap`-compatible) or
  /// exercise maps (workout, `recoveryExercises()`-shaped). Kept as raw maps
  /// rather than a typed `DietMeal`/`WorkoutExercise` here so this dashboard
  /// model never has to import the Diet/Workout features' types — each
  /// feature converts at its own boundary (see DietController.effectiveMealsFor).
  /// `items` above stays the short informational bullet list shown on the
  /// Dashboard's own Recovery Panel; `meals`/exercises are what the actual
  /// Diet/Workout screens apply for today.
  final List<Map<String, dynamic>> meals;

  Map<String, dynamic> toMap() => {
    if (mode != null) 'mode': mode,
    'title': title,
    'items': items,
    if (meals.isNotEmpty) 'meals': meals,
  };

  factory HealthPlanBlock.fromMap(Map<String, dynamic> m) => HealthPlanBlock(
    title: (m['title'] as String?) ?? (m['focus'] as String?) ?? '',
    items: (m['items'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    mode: m['mode'] as String?,
    meals: (m['meals'] as List?)?.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() ?? const [],
  );
}

/// The computed override — `zitlas_health_today`'s shape.
class HealthAdjustment {
  const HealthAdjustment({
    required this.date,
    required this.status,
    required this.symptoms,
    required this.bodyParts,
    required this.oldStepsGoal,
    required this.stepsGoal,
    this.severity,
    this.painLevel,
    this.sleepHours,
    this.stressLevel,
    this.note = '',
    this.safety = false,
    this.workout,
    this.diet,
    this.createdAt,
  });

  final String date;
  final String status;
  final List<String> symptoms;
  final List<String> bodyParts;
  final String? severity;
  final int? painLevel;
  final double? sleepHours;
  final int? stressLevel;
  final String note;

  /// Severe/critical report — all workout generation suppressed.
  final bool safety;
  final HealthPlanBlock? workout;
  final HealthPlanBlock? diet;
  final int oldStepsGoal;

  /// `null` == the website's `'Rest'` sentinel (goal paused for today).
  final int? stepsGoal;
  final String? createdAt;

  bool get isRest => stepsGoal == null;

  /// What `getEffectiveGoal()` derives from this record: a paused goal is 0.
  int get effectiveStepsGoal => stepsGoal ?? 0;

  String get stepsGoalLabel => stepsGoal == null ? 'Rest' : stepsGoal.toString();

  Map<String, dynamic> toMap() => {
    'date': date,
    'status': status,
    'symptoms': symptoms,
    'bodyParts': bodyParts,
    'severity': severity,
    'painLevel': painLevel,
    'sleepHours': sleepHours,
    'stressLevel': stressLevel,
    'note': note,
    'safety': safety,
    'workout': workout?.toMap(),
    // Full round trip (title/items/mode/meals) — a previous version of this
    // map hand-flattened this to {focus, items} only, silently dropping the
    // `meals` list on every save/load cycle, which is exactly what made the
    // recovery-day diet override a no-op end to end.
    'diet': diet?.toMap(),
    'oldStepsGoal': oldStepsGoal,
    'stepsGoal': stepsGoal ?? 'Rest',
    'createdAt': createdAt,
  };

  factory HealthAdjustment.fromMap(Map<String, dynamic> m) {
    final raw = m['stepsGoal'];
    return HealthAdjustment(
      date: (m['date'] as String?) ?? '',
      status: (m['status'] as String?) ?? 'other',
      symptoms: (m['symptoms'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      bodyParts: (m['bodyParts'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      severity: m['severity'] as String?,
      painLevel: (m['painLevel'] as num?)?.toInt(),
      sleepHours: (m['sleepHours'] as num?)?.toDouble(),
      stressLevel: (m['stressLevel'] as num?)?.toInt(),
      note: (m['note'] as String?) ?? '',
      safety: m['safety'] == true,
      workout: m['workout'] is Map
          ? HealthPlanBlock.fromMap((m['workout'] as Map).cast<String, dynamic>())
          : null,
      diet: m['diet'] is Map
          ? HealthPlanBlock.fromMap((m['diet'] as Map).cast<String, dynamic>())
          : null,
      oldStepsGoal: (m['oldStepsGoal'] as num?)?.toInt() ?? 7000,
      stepsGoal: raw is num ? raw.toInt() : null,
      createdAt: m['createdAt'] as String?,
    );
  }
}

/// One row of `zitlas_health_history` — drives the recovery timeline.
class HealthHistoryEntry {
  const HealthHistoryEntry({
    required this.date,
    required this.status,
    this.severity,
    this.safety = false,
  });

  final String date;
  final String status;
  final String? severity;
  final bool safety;

  Map<String, dynamic> toMap() =>
      {'date': date, 'status': status, 'severity': severity, 'safety': safety};

  factory HealthHistoryEntry.fromMap(Map<String, dynamic> m) => HealthHistoryEntry(
    date: (m['date'] as String?) ?? '',
    status: (m['status'] as String?) ?? 'other',
    severity: m['severity'] as String?,
    safety: m['safety'] == true,
  );
}

/// `recoveryMeals(kind)` (health-status.js:97-145) — the ACTUAL replacement
/// meal list for a recovery day, ported field-for-field. This is what makes
/// the diet override real rather than informational: DietController swaps
/// today's `DietDay.meals` for exactly this list (via `DietMeal.fromMap`,
/// which already understands this shape) when [healthOverrideAppliesTo]
/// says today's date/weekday matches and no coach plan is active.
List<Map<String, dynamic>> _recoveryMeals(String kind) {
  Map<String, dynamic> m(String name, String time, List<String> foods, String purpose, String emoji) => {
    'meal_name': name,
    'time': time,
    'foods': foods,
    'purpose': purpose,
    'emoji': emoji,
    'color': '#F59E0B',
    '_recovery': true,
  };

  switch (kind) {
    case 'fever':
      return [
        m('Breakfast', '8:00 AM', ['Moong dal khichdi', 'Curd'], 'Easy to digest · gentle protein', '🥣'),
        m('Mid-Morning', '11:00 AM', ['Coconut water', 'Orange or amla'], 'Electrolytes · Vitamin C', '🥥'),
        m('Lunch', '1:30 PM', ['Vegetable soup', 'Soft rice with dal'], 'Hydrating · light', '🍲'),
        m('Snacks', '4:30 PM', ['Banana', 'ORS / electrolyte drink'], 'Energy · hydration', '🍌'),
        m('Dinner', '7:30 PM', ['Light khichdi', 'Boiled vegetables'], 'Early, light dinner for recovery', '🥣'),
      ];
    case 'cold':
      return [
        m('Breakfast', '8:00 AM', ['Warm oats with honey', 'Ginger tea'], 'Warm & soothing', '🥣'),
        m('Mid-Morning', '11:00 AM', ['Warm lemon water', 'Citrus fruit'], 'Vitamin C', '🍋'),
        m('Lunch', '1:30 PM', ['Dal rice', 'Warm sabzi', 'Rasam or clear soup'], 'Warm, easy comfort food', '🍛'),
        m('Snacks', '4:30 PM', ['Ginger tea', 'Roasted makhana'], 'Avoid cold drinks today', '🫖'),
        m('Dinner', '7:30 PM', ['Vegetable soup', 'Soft roti + sabzi', 'Turmeric milk before bed'],
            'Turmeric milk supports recovery overnight', '🍲'),
      ];
    case 'inflammation':
      return [
        m('Breakfast', '8:00 AM', ['Turmeric oats with berries', 'Walnuts'], 'Anti-inflammatory start', '🥣'),
        m('Mid-Morning', '11:00 AM', ['Ginger tea', 'Seasonal fruit'], 'Hydration + antioxidants', '🫖'),
        m('Lunch', '1:30 PM', ['Dal + rice', 'Leafy-green sabzi', 'Curd'], 'Greens + protein for repair', '🍛'),
        m('Snacks', '4:30 PM', ['Handful of almonds', 'Coconut water'], 'Magnesium + electrolytes', '🥥'),
        m('Dinner', '7:30 PM', ['Khichdi or dal + roti', 'Steamed vegetables'], 'Light, anti-inflammatory dinner', '🥗'),
      ];
    case 'sleep':
      return [
        m('Breakfast', '8:00 AM', ['Banana oats', 'Handful of almonds'], 'Magnesium-rich start', '🥣'),
        m('Mid-Morning', '11:00 AM', ['Fruit + pumpkin seeds'], 'Steady energy, no caffeine after 2 PM', '🎃'),
        m('Lunch', '1:30 PM', ['Rice + dal', 'Palak (spinach) sabzi', 'Curd'], 'Magnesium + comfortable carbs', '🍛'),
        m('Snacks', '4:30 PM', ['Roasted chana', 'Herbal tea (no caffeine)'], 'Light afternoon energy', '🫖'),
        m('Dinner', '7:00 PM', ['Light roti + sabzi', 'Warm milk before bed'], 'Earlier, lighter dinner for better sleep', '🥛'),
      ];
    case 'stress':
      return [
        m('Breakfast', '8:00 AM', ['Oats with flaxseed', 'Walnuts'], 'Complex carbs + omega-3 for mood', '🥣'),
        m('Mid-Morning', '11:00 AM', ['Fruit', 'Green tea (limit caffeine)'], 'Steady blood sugar', '🍎'),
        m('Lunch', '1:30 PM', ['Brown rice + dal', 'Vegetable sabzi', 'Salad'], 'Stable-energy lunch', '🍛'),
        m('Snacks', '4:30 PM', ['Dark roasted chana', 'Banana'], 'Avoid heavy caffeine today', '🍌'),
        m('Dinner', '7:30 PM', ['Roti + paneer or dal', 'Steamed vegetables'], 'Balanced, calming dinner', '🥗'),
      ];
    default: // 'injury' / default recovery
      return [
        m('Breakfast', '8:00 AM', ['Eggs or paneer bhurji', 'Whole-grain toast'], 'Extra protein for tissue repair', '🍳'),
        m('Mid-Morning', '11:00 AM', ['Berries or citrus fruit', 'Walnuts'], 'Antioxidants + omega-3', '🫐'),
        m('Lunch', '1:30 PM', ['Dal + rice', 'Turmeric sabzi', 'Curd'], 'Anti-inflammatory + protein', '🍛'),
        m('Snacks', '4:30 PM', ['Sprouts chaat or roasted chana'], 'Protein top-up', '🥗'),
        m('Dinner', '7:30 PM', ['Roti + paneer/chicken', 'Leafy greens'], 'Repair-focused dinner', '🥘'),
      ];
  }
}

/// The ACTUAL replacement exercise list for a recovery-day workout — new
/// territory beyond the website (which only ever showed `workout.items` as
/// informational bullet text; `day.js`/`weekly-plan.js` never substitute
/// real exercises). `WorkoutDay`/`WorkoutExercise`-shaped maps
/// (`name`/`sets`/`reps_or_duration`/`tip`), consistent with [_recoveryMeals]'s
/// approach of making the adjustment something the Workout screen can
/// actually render instead of only a claim on the Dashboard card.
List<Map<String, dynamic>> _recoveryExercises(String mode) {
  Map<String, dynamic> e(String name, String sets, String repsOrDuration, {String? tip}) => {
    'name': name,
    'sets': sets,
    'reps_or_duration': repsOrDuration,
    if (tip != null) 'tip': tip,
  };

  switch (mode) {
    case 'none':
    case 'rest':
      return const [];
    case 'mobility':
      return [
        e('Full-Body Mobility Flow', '1', '15 min', tip: 'Move gently through each joint\'s full range — no strain.'),
        e('Breathing Exercises', '3', '5 min', tip: '4-7-8 pattern: inhale 4s, hold 7s, exhale 8s.'),
        e('Easy Walk', '1', '10-15 min', tip: 'Only if energy allows — stop if you feel worse.'),
      ];
    case 'reduced':
      return [
        e('Easy Walk or Light Cycling', '1', '20 min',
            tip: 'Keep effort conversational — this is active recovery, not training.'),
        e('Light Mobility Stretching', '1', '10 min'),
      ];
    case 'modified':
      return [
        e('Gentle Mobility (pain-free range only)', '2', '10 min', tip: 'Stop immediately at any sharp pain.'),
        e('Easy Walk', '1', '15 min', tip: 'Only if it does not aggravate the injury.'),
      ];
    default:
      return const [];
  }
}

/// `computeAdjustments(report)` (health-status.js:147-276) — every branch,
/// threshold and copy string reproduced exactly.
///
/// [baseStepsGoal] is `zitlas_calculations.daily_steps_goal` (default 7000 on
/// the website). [hasCriticalCondition] / [hasAsthma] come from
/// `zitlas_precautions`.
HealthAdjustment computeHealthAdjustments(
  HealthReport report, {
  required int baseStepsGoal,
  bool hasCriticalCondition = false,
  bool hasAsthma = false,
  DateTime? now,
}) {
  final n = now ?? DateTime.now();
  final date = '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  final steps = baseStepsGoal;
  bool has(String s) => report.symptoms.contains(s);

  HealthAdjustment build({
    bool safety = false,
    HealthPlanBlock? workout,
    HealthPlanBlock? diet,
    int? stepsGoal = -1, // -1 sentinel = "unchanged (base goal)"
  }) {
    return HealthAdjustment(
      date: date,
      status: report.status,
      symptoms: report.symptoms,
      bodyParts: report.bodyParts,
      severity: report.severity,
      painLevel: report.painLevel,
      sleepHours: report.sleepHours,
      stressLevel: report.stressLevel,
      note: report.note,
      safety: safety,
      workout: workout,
      diet: diet,
      oldStepsGoal: steps,
      stepsGoal: stepsGoal == -1 ? steps : stepsGoal,
      createdAt: n.toIso8601String(),
    );
  }

  // ── SAFETY GATE (checked first, overrides everything) ──
  if (report.severity == 'severe' ||
      has('Chest Pain') ||
      has('Difficulty Breathing') ||
      (report.status == 'injured' && report.painLevel >= 8) ||
      (report.status == 'sick' && hasCriticalCondition)) {
    return build(
      safety: true,
      workout: HealthPlanBlock(mode: 'none', title: '⚠ No workout today', items: const [
        'Seek medical attention before exercising.',
        'Rest and hydrate.',
        'Resume training only after you feel fully recovered or are cleared by a doctor.',
      ], meals: _recoveryExercises('none')),
      diet: HealthPlanBlock(title: 'Gentle recovery nutrition', items: const [
        'Light, easy-to-digest meals (khichdi, soup)',
        'Electrolytes / coconut water',
        'Small frequent portions',
        'Plenty of water',
      ], meals: _recoveryMeals('fever')),
      stepsGoal: null, // 'Rest'
    );
  }

  if (report.status == 'great') {
    return build(); // normal plan, no overrides
  }

  if (report.status == 'sick' || report.status == 'unwell' || report.status == 'other') {
    final feverish =
        has('Fever') || has('Vomiting') || has('Diarrhea') || has('Food Poisoning');
    final coldish = has('Cold') || has('Cough') || has('Sore Throat');
    final weak = has('Weakness') || has('Fatigue') || has('Body Pain');

    if (feverish || report.status == 'sick') {
      return build(
        workout: HealthPlanBlock(mode: 'rest', title: 'Workout cancelled — Recovery Day', items: const [
          'Complete rest',
          'Hydration: 3+ litres through the day',
          'Deep breathing: 5 minutes, 3 times',
          'Gentle full-body stretching: 10 minutes',
        ], meals: _recoveryExercises('rest')),
        diet: HealthPlanBlock(title: 'Fever recovery — light & hydrating', items: const [
          'Vegetable / chicken soup',
          'Khichdi (easy to digest)',
          'Coconut water + electrolytes',
          'Vitamin C fruits (orange, amla)',
          'Light protein (curd, dal, boiled eggs)',
        ], meals: _recoveryMeals('fever')),
        stepsGoal: feverish && report.severity == 'moderate' ? null : 2000,
      );
    }
    if (coldish) {
      return build(
        workout: HealthPlanBlock(mode: 'reduced', title: 'Intensity reduced ~60%', items: [
          'Skip high-intensity work today',
          'Easy walk or light mobility only',
          'Stop if breathing feels harder than usual',
          if (hasAsthma) 'Asthma: keep your inhaler nearby, train indoors',
        ], meals: _recoveryExercises('reduced')),
        diet: HealthPlanBlock(title: 'Cold recovery — warm & soothing', items: const [
          'Warm fluids through the day',
          'Turmeric milk before bed',
          'Ginger tea',
          'Warm soups',
          'Avoid cold drinks / ice cream',
        ], meals: _recoveryMeals('cold')),
        stepsGoal: (steps * 0.5).round(),
      );
    }
    if (weak) {
      return build(
        workout: HealthPlanBlock(mode: 'mobility', title: 'Mobility only', items: const [
          'Gentle stretching: 15 minutes',
          'Easy walk if energy allows',
          'No strength or cardio today',
        ], meals: _recoveryExercises('mobility')),
        diet: HealthPlanBlock(title: 'Anti-inflammatory + energy', items: const [
          'Anti-inflammatory foods (turmeric, ginger, leafy greens)',
          'Balanced carbs for energy',
          'Extra hydration',
        ], meals: _recoveryMeals('inflammation')),
        stepsGoal: (steps * 0.4).round(),
      );
    }
    return build(
      workout: HealthPlanBlock(mode: 'reduced', title: 'Take it easier today', items: const [
        'Reduce intensity ~40%',
        'Stop early if you feel worse',
      ], meals: _recoveryExercises('reduced')),
      diet: HealthPlanBlock(title: 'Light, regular meals', items: const [
        'Stick to simple whole foods',
        'Hydrate well',
      ], meals: _recoveryMeals('inflammation')),
      stepsGoal: (steps * 0.6).round(),
    );
  }

  if (report.status == 'injured') {
    final parts = report.bodyParts.map((p) => p.toLowerCase()).toList();
    final lower = parts.any((p) => const ['knee', 'ankle', 'foot', 'hip'].contains(p));
    final back = parts.any((p) => p.contains('back'));
    final upper = parts
        .any((p) => const ['neck', 'shoulder', 'chest', 'elbow', 'wrist'].contains(p));
    return build(
      workout: HealthPlanBlock(mode: 'modified', title: 'Workout modified around your injury', items: [
        if (lower) 'Leg work removed — upper-body strength only (seated where possible)',
        if (back)
          'No deadlifts, no squats, no loaded spinal movement — core-safe work only '
              '(bird-dog, dead bug)',
        if (upper) 'Affected-arm/shoulder work removed — lower-body and walking focus',
        'Stay strictly pain-free: sharp pain = stop immediately',
      ], meals: _recoveryExercises('modified')),
      diet: HealthPlanBlock(title: 'Injury recovery', items: const [
        'Extra protein for tissue repair',
        'Anti-inflammatory foods (omega-3, turmeric, berries)',
      ], meals: _recoveryMeals('injury')),
      stepsGoal: lower ? 1500 : (steps * 0.7).round(),
    );
  }

  if (report.status == 'poor_sleep') {
    final hrs = report.sleepHours;
    final sleepDiet = HealthPlanBlock(title: 'Sleep support', items: const [
      'Magnesium-rich foods (spinach, almonds, pumpkin seeds, banana)',
      'No caffeine after 2 PM',
      'Lighter dinner, earlier',
    ], meals: _recoveryMeals('sleep'));
    if (hrs < 5) {
      return build(
        workout: HealthPlanBlock(mode: 'reduced', title: 'Light recovery session only', items: const [
          'Skip intense training on <5h sleep',
          '15-20 min easy walk',
          'Light stretching before bed tonight',
        ], meals: _recoveryExercises('reduced')),
        diet: sleepDiet,
        stepsGoal: (steps * 0.6).round(),
      );
    }
    return build(
      workout: HealthPlanBlock(mode: 'reduced', title: 'Reduce intensity today', items: const [
        'Drop ~30% of planned intensity/volume',
        'Prioritise an earlier night tonight',
      ], meals: _recoveryExercises('reduced')),
      diet: sleepDiet,
      stepsGoal: (steps * 0.8).round(),
    );
  }

  if (report.status == 'stress') {
    final lvl = report.stressLevel;
    return build(
      workout: HealthPlanBlock(
        mode: lvl >= 8 ? 'mobility' : 'reduced',
        title: lvl >= 8 ? 'Calming movement only' : 'Moderate session',
        items: lvl >= 8
            ? const [
                'Yoga or gentle stretching: 20 minutes',
                'Breathing exercises: 4-7-8 pattern, 5 minutes',
                'Easy outdoor walk',
              ]
            : const [
                'Moderate workout is fine — it helps stress',
                'Finish with 5 minutes of slow breathing',
              ],
        // Stress alone doesn't warrant zeroing out training the way sick/
        // injured do — a moderate session stays a normal (unmodified)
        // workout, matching the item text above ("fine — it helps stress").
        meals: lvl >= 8 ? _recoveryExercises('mobility') : const [],
      ),
      diet: HealthPlanBlock(title: 'Stress support', items: const [
        'Complex carbs (oats, brown rice) for stable mood',
        'Omega-3 sources (walnuts, flaxseed)',
        'Limit caffeine today',
      ], meals: _recoveryMeals('stress')),
      stepsGoal: (steps * 0.9).round(),
    );
  }

  return build();
}
