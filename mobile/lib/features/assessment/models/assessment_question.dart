/// Question definitions ported field-for-field from
/// `frontend/pages/dashboard/ai-coach/ai-coach.js` (`QUESTIONS`,
/// `GF_QUESTIONS`, `TF_QUESTIONS`, `SUPPLEMENT_QUESTION`, `WHEEL_CONFIG`).
/// Every prompt, hint, option label/value, placeholder, and validation range
/// is transcribed verbatim — this is the single source of truth for the
/// Assessment step content, not paraphrased.
library;

enum AssessmentQuestionType { text, options, multiselect, slider }

class AssessmentOption {
  const AssessmentOption({required this.label, required this.value, this.icon});
  final String label;
  final String value;
  final String? icon;
}

/// A wheel-picker numeric field's config — `WHEEL_CONFIG[field]`.
class WheelConfig {
  const WheelConfig({this.min, this.max, this.values, required this.unit, required this.defaultVal});

  final int? min;
  final int? max;

  /// Discrete presets (e.g. `available_time`'s [5,10,...,90]) — takes
  /// priority over `min`/`max` when present.
  final List<int>? values;
  final String unit;
  final num defaultVal;
}

class AssessmentQuestion {
  const AssessmentQuestion({
    required this.field,
    required this.prompt,
    this.hint,
    required this.type,
    this.placeholder,
    this.options = const [],
    this.min,
    this.max,
    this.defaultVal,
    this.validate,
    this.parse,
    this.errMsg,
  });

  final String field;
  final String prompt;
  final String? hint;
  final AssessmentQuestionType type;
  final String? placeholder;
  final List<AssessmentOption> options;

  // slider only
  final int? min;
  final int? max;
  final num? defaultVal;

  /// Returns true if the raw text is valid — `text` type only.
  final bool Function(String raw)? validate;

  /// Parses the raw text/value into the stored answer type.
  final dynamic Function(String raw)? parse;
  final String? errMsg;
}

/// `WHEEL_CONFIG` — numeric `text`-type fields dispatched to a wheel picker
/// instead of a plain text field. Height/weight/goal-weight additionally get
/// the cm↔ft-in / kg↔lbs unit toggle (`mountHeightPicker`/`mountWeightPicker`
/// on the website); `sleep_hours` and `available_time` (default flow only)
/// are plain wheels.
const Map<String, WheelConfig> kWheelConfig = {
  'age': WheelConfig(min: 13, max: 100, unit: 'years', defaultVal: 22),
  'height_cm': WheelConfig(min: 120, max: 230, unit: 'cm', defaultVal: 170),
  'weight_kg': WheelConfig(min: 25, max: 250, unit: 'kg', defaultVal: 70),
  'goal_weight_kg': WheelConfig(min: 25, max: 250, unit: 'kg', defaultVal: 65),
  'sleep_hours': WheelConfig(min: 4, max: 12, unit: 'hours', defaultVal: 8),
  'available_time': WheelConfig(values: [5, 10, 15, 20, 25, 30, 45, 60, 75, 90], unit: 'min', defaultVal: 30),
};

bool _ageValid(String v) {
  final n = int.tryParse(v);
  return n != null && n >= 13 && n <= 100;
}

bool _heightValid(String v) {
  final n = double.tryParse(v);
  return n != null && n >= 120 && n <= 230;
}

bool _weightValid(String v) {
  final n = double.tryParse(v);
  return n != null && n >= 25 && n <= 250;
}

bool _sleepValid(String v) {
  final n = double.tryParse(v);
  return n != null && n >= 2 && n <= 14;
}

dynamic _medicalParse(String v) {
  final s = v.trim().toLowerCase();
  return (s == 'none' || s == 'no' || s == 'n/a') ? 'none' : v.trim();
}

const _medicalConditionsQuestion = AssessmentQuestion(
  field: 'medical_conditions',
  prompt: 'Do you have any medical conditions?',
  hint: 'Type "none" if you don\'t have any',
  type: AssessmentQuestionType.text,
  placeholder: 'e.g. diabetes, thyroid… or "none"',
  validate: _medicalConditionsValid,
  parse: _medicalParse,
  errMsg: 'Please enter a value or type "none"',
);

bool _medicalConditionsValid(String v) => v.trim().isNotEmpty;

/// `SUPPLEMENT_QUESTION` — shared across all three flows.
const supplementQuestion = AssessmentQuestion(
  field: 'supplements_used',
  prompt: 'Do you use any supplements?',
  hint: 'If you don’t, we’ll build your protein targets from whole foods only',
  type: AssessmentQuestionType.multiselect,
  options: [
    AssessmentOption(label: '❌ I don’t use supplements', value: 'none'),
    AssessmentOption(label: 'Whey Protein', value: 'Whey Protein'),
    AssessmentOption(label: 'Creatine', value: 'Creatine'),
    AssessmentOption(label: 'Multivitamin', value: 'Multivitamin'),
    AssessmentOption(label: 'Fish Oil', value: 'Fish Oil'),
    AssessmentOption(label: 'Vitamin D', value: 'Vitamin D'),
    AssessmentOption(label: 'BCAA', value: 'BCAA'),
    AssessmentOption(label: 'Mass Gainer', value: 'Mass Gainer'),
    AssessmentOption(label: 'Electrolytes', value: 'Electrolytes'),
    AssessmentOption(label: 'Other', value: 'Other'),
  ],
);

/// `QUESTIONS` (15) — default flow, used for `lose_weight` AND `muscle_gain`
/// (`getActiveQuestions()` only branches on general_fitness/transformation).
final List<AssessmentQuestion> defaultQuestions = [
  AssessmentQuestion(
    field: 'age',
    prompt: 'How old are you?',
    hint: 'Enter your age in years',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 22',
    validate: _ageValid,
    parse: (v) => int.parse(v),
    errMsg: 'Please enter a valid age (13–100)',
  ),
  const AssessmentQuestion(
    field: 'gender',
    prompt: 'What is your gender?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '👨', label: 'Male', value: 'male'),
      AssessmentOption(icon: '👩', label: 'Female', value: 'female'),
      AssessmentOption(icon: '🧑', label: 'Other', value: 'other'),
    ],
  ),
  AssessmentQuestion(
    field: 'height_cm',
    prompt: 'How tall are you?',
    hint: 'Enter your height in centimetres (cm)',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 170',
    validate: _heightValid,
    parse: (v) => double.parse(v),
    errMsg: 'Please enter a valid height (120–230 cm)',
  ),
  AssessmentQuestion(
    field: 'weight_kg',
    prompt: 'What is your current weight?',
    hint: 'Enter your weight in kilograms (kg)',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 78',
    validate: _weightValid,
    parse: (v) => double.parse(v),
    errMsg: 'Please enter a valid weight (25–250 kg)',
  ),
  AssessmentQuestion(
    field: 'goal_weight_kg',
    prompt: 'What is your goal weight?',
    hint: 'The weight you want to reach (in kg)',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 65',
    validate: _weightValid,
    parse: (v) => double.parse(v),
    errMsg: 'Please enter a valid goal weight (25–250 kg)',
  ),
  const AssessmentQuestion(
    field: 'activity_level',
    prompt: 'How active are you in daily life?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '🛋️', label: 'Mostly sitting (desk/student)', value: 'sedentary'),
      AssessmentOption(icon: '🚶', label: 'Light activity (walks, chores)', value: 'light'),
      AssessmentOption(icon: '🏃', label: 'Moderate (3–4x exercise/week)', value: 'moderate'),
      AssessmentOption(icon: '💪', label: 'Very active (daily exercise)', value: 'active'),
    ],
  ),
  const AssessmentQuestion(
    field: 'diet_preference',
    prompt: 'What type of food do you eat?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '🌿', label: 'Pure Vegetarian', value: 'vegetarian'),
      AssessmentOption(icon: '🍗', label: 'Non-Vegetarian', value: 'non-vegetarian'),
      AssessmentOption(icon: '🥚', label: 'Eggetarian (eggs only, no meat)', value: 'eggetarian'),
      AssessmentOption(icon: '🤷', label: 'Mixed / No preference', value: 'mixed'),
    ],
  ),
  const AssessmentQuestion(
    field: 'living_situation',
    prompt: 'Where do you eat most of your meals?',
    hint: 'This shapes your entire meal plan',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '🏠', label: 'At Home (home-cooked)', value: 'home'),
      AssessmentOption(icon: '🏫', label: 'Hostel / PG', value: 'hostel'),
      AssessmentOption(icon: '🏢', label: 'Office / Rented room', value: 'pg'),
      AssessmentOption(icon: '🏟️', label: 'Sports Academy / Camp', value: 'other'),
    ],
  ),
  const AssessmentQuestion(
    field: 'occupation',
    prompt: 'What best describes your occupation?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '📚', label: 'Student', value: 'student'),
      AssessmentOption(icon: '💼', label: 'Office Worker', value: 'office_worker'),
      AssessmentOption(icon: '🔧', label: 'Physical / Field Worker', value: 'physical_worker'),
      AssessmentOption(icon: '🏠', label: 'Homemaker / Other', value: 'other'),
    ],
  ),
  const AssessmentQuestion(
    field: 'workout_preference',
    prompt: 'What kind of workout can you do?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '🏠', label: 'Home workout (no equipment)', value: 'home'),
      AssessmentOption(icon: '🏋️', label: 'Gym access', value: 'gym'),
      AssessmentOption(icon: '🚶', label: 'Walking / Running only', value: 'walking'),
      AssessmentOption(icon: '❌', label: 'No workout currently', value: 'none'),
    ],
  ),
  AssessmentQuestion(
    field: 'sleep_hours',
    prompt: 'How many hours of sleep do you get?',
    hint: 'Average hours per night',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 7',
    validate: _sleepValid,
    parse: (v) => double.parse(v),
    errMsg: 'Please enter 2–14 hours',
  ),
  const AssessmentQuestion(
    field: 'stress_level',
    prompt: 'How would you rate your daily stress level?',
    hint: '1 = very calm, 10 = extremely stressed',
    type: AssessmentQuestionType.slider,
    min: 1,
    max: 10,
    defaultVal: 5,
  ),
  AssessmentQuestion(
    field: 'available_time',
    prompt: 'How much time can you realistically dedicate each day?',
    hint: 'Be honest — a 10-minute workout you actually do beats a 60-minute one you skip. '
        'We will never give you a longer workout than this.',
    type: AssessmentQuestionType.text,
    parse: (v) => int.parse(v),
  ),
  const AssessmentQuestion(
    field: 'budget',
    prompt: 'How much do you usually spend on food each day?',
    hint: 'Your meal plan will be built to genuinely fit this — no fancy ingredients you can’t afford',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '💰', label: '₹0–50 (hostel mess)', value: '₹50/day'),
      AssessmentOption(icon: '💰', label: '₹50–100', value: '₹100/day'),
      AssessmentOption(icon: '💰', label: '₹100–200', value: '₹150/day'),
      AssessmentOption(icon: '💰', label: '₹200+', value: '₹250/day'),
    ],
  ),
  supplementQuestion,
  _medicalConditionsQuestion,
];

/// `GF_QUESTIONS` (14) — `general_fitness` goal.
final List<AssessmentQuestion> generalFitnessQuestions = [
  AssessmentQuestion(
    field: 'age',
    prompt: 'How old are you?',
    hint: 'Enter your age in years',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 22',
    validate: _ageValid,
    parse: (v) => int.parse(v),
    errMsg: 'Please enter a valid age (13–100)',
  ),
  const AssessmentQuestion(
    field: 'gender',
    prompt: 'What is your gender?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '👨', label: 'Male', value: 'male'),
      AssessmentOption(icon: '👩', label: 'Female', value: 'female'),
      AssessmentOption(icon: '🧑', label: 'Other', value: 'other'),
    ],
  ),
  AssessmentQuestion(
    field: 'height_cm',
    prompt: 'How tall are you?',
    hint: 'Enter your height in centimetres (cm)',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 170',
    validate: _heightValid,
    parse: (v) => double.parse(v),
    errMsg: 'Please enter a valid height (120–230 cm)',
  ),
  AssessmentQuestion(
    field: 'weight_kg',
    prompt: 'What is your current weight?',
    hint: 'Enter your weight in kilograms (kg)',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 70',
    validate: _weightValid,
    parse: (v) => double.parse(v),
    errMsg: 'Please enter a valid weight (25–250 kg)',
  ),
  const AssessmentQuestion(
    field: 'activity_level',
    prompt: 'How active are you in daily life?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '🛋️', label: 'Sedentary (mostly sitting)', value: 'sedentary'),
      AssessmentOption(icon: '🚶', label: 'Lightly Active (walks, chores)', value: 'light'),
      AssessmentOption(icon: '🏃', label: 'Moderately Active (3–4x/week)', value: 'moderate'),
      AssessmentOption(icon: '💪', label: 'Very Active (daily exercise)', value: 'active'),
    ],
  ),
  const AssessmentQuestion(
    field: 'occupation',
    prompt: 'What best describes your occupation?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '📚', label: 'Student', value: 'student'),
      AssessmentOption(icon: '💼', label: 'Working Professional', value: 'office_worker'),
      AssessmentOption(icon: '🏢', label: 'Business Owner', value: 'freelancer'),
      AssessmentOption(icon: '🏠', label: 'Homemaker', value: 'other'),
    ],
  ),
  const AssessmentQuestion(
    field: 'living_situation',
    prompt: 'Where do you currently live?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '🏫', label: 'Hostel', value: 'hostel'),
      AssessmentOption(icon: '🏠', label: 'PG', value: 'pg'),
      AssessmentOption(icon: '🏡', label: 'Home', value: 'home'),
      AssessmentOption(icon: '🚪', label: 'Living Alone', value: 'rented'),
    ],
  ),
  const AssessmentQuestion(
    field: 'diet_preference',
    prompt: 'What type of food do you eat?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '🌿', label: 'Pure Vegetarian', value: 'vegetarian'),
      AssessmentOption(icon: '🍗', label: 'Non-Vegetarian', value: 'non-vegetarian'),
      AssessmentOption(icon: '🥚', label: 'Eggetarian', value: 'eggetarian'),
      AssessmentOption(icon: '🤷', label: 'No preference / Mixed', value: 'mixed'),
    ],
  ),
  const AssessmentQuestion(
    field: 'health_goals',
    prompt: 'What would you like to improve?',
    type: AssessmentQuestionType.multiselect,
    options: [
      AssessmentOption(label: 'More Energy', value: 'energy'),
      AssessmentOption(label: 'Better Health', value: 'health'),
      AssessmentOption(label: 'Improve Fitness', value: 'fitness'),
      AssessmentOption(label: 'Build Healthy Habits', value: 'habits'),
      AssessmentOption(label: 'Better Mobility', value: 'mobility'),
      AssessmentOption(label: 'Better Endurance', value: 'endurance'),
      AssessmentOption(label: 'Better Strength', value: 'strength'),
      AssessmentOption(label: 'Improve Posture', value: 'posture'),
      AssessmentOption(label: 'Reduce Stress', value: 'reduce_stress'),
      AssessmentOption(label: 'Better Sleep', value: 'sleep'),
    ],
  ),
  const AssessmentQuestion(
    field: 'fitness_level',
    prompt: 'What is your current fitness level?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '🌱', label: 'Beginner — just starting out', value: 'beginner'),
      AssessmentOption(icon: '🔥', label: 'Intermediate — some exercise history', value: 'intermediate'),
      AssessmentOption(icon: '⚡', label: 'Advanced — regular consistent training', value: 'advanced'),
    ],
  ),
  const AssessmentQuestion(
    field: 'workout_preference',
    prompt: 'What kind of workout do you prefer?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '🏠', label: 'Home Workout', value: 'home'),
      AssessmentOption(icon: '🏋️', label: 'Gym Workout', value: 'gym'),
      AssessmentOption(icon: '🚶', label: 'Walking', value: 'walking'),
      AssessmentOption(icon: '🔀', label: 'Mixed', value: 'mixed'),
    ],
  ),
  const AssessmentQuestion(
    field: 'available_time',
    prompt: 'How much time can you realistically dedicate each day?',
    hint: 'Your workouts will never run longer than this',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '⚡', label: '10 min', value: '10'),
      AssessmentOption(icon: '🕐', label: '20 min', value: '20'),
      AssessmentOption(icon: '🕑', label: '30 min', value: '30'),
      AssessmentOption(icon: '🕒', label: '45 min', value: '45'),
      AssessmentOption(icon: '🕓', label: '60+ min', value: '60'),
    ],
  ),
  AssessmentQuestion(
    field: 'sleep_hours',
    prompt: 'How many hours of sleep do you get?',
    hint: 'Average hours per night',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 7',
    validate: _sleepValid,
    parse: (v) => double.parse(v),
    errMsg: 'Please enter 2–14 hours',
  ),
  const AssessmentQuestion(
    field: 'stress_level',
    prompt: 'How would you rate your daily stress level?',
    hint: '1 = very calm, 10 = very stressed',
    type: AssessmentQuestionType.slider,
    min: 1,
    max: 10,
    defaultVal: 5,
  ),
  supplementQuestion,
];

/// `TF_QUESTIONS` (13) — `transformation` goal.
final List<AssessmentQuestion> transformationQuestions = [
  AssessmentQuestion(
    field: 'age',
    prompt: 'How old are you?',
    hint: 'Enter your age in years',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 22',
    validate: _ageValid,
    parse: (v) => int.parse(v),
    errMsg: 'Please enter a valid age (13–100)',
  ),
  const AssessmentQuestion(
    field: 'gender',
    prompt: 'What is your gender?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '👨', label: 'Male', value: 'male'),
      AssessmentOption(icon: '👩', label: 'Female', value: 'female'),
      AssessmentOption(icon: '🧑', label: 'Other', value: 'other'),
    ],
  ),
  AssessmentQuestion(
    field: 'height_cm',
    prompt: 'How tall are you?',
    hint: 'Height in centimetres (cm)',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 175',
    validate: _heightValid,
    parse: (v) => double.parse(v),
    errMsg: 'Please enter a valid height (120–230 cm)',
  ),
  AssessmentQuestion(
    field: 'weight_kg',
    prompt: 'What is your current weight?',
    hint: 'Weight in kilograms (kg)',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 75',
    validate: _weightValid,
    parse: (v) => double.parse(v),
    errMsg: 'Please enter a valid weight (25–250 kg)',
  ),
  // A transformation is defined by a current -> target trajectory, so the
  // target is REQUIRED here, not optional. This question was missing entirely:
  // the set asked current weight and then jumped to the transformation style,
  // leaving the calorie/deficit maths with no destination to aim at. Same
  // field name and validator as the weight-loss set so every downstream
  // consumer (calculations, prompt payload, coach view) already understands it.
  AssessmentQuestion(
    field: 'goal_weight_kg',
    prompt: 'What is your target weight?',
    hint: 'The weight you want to reach through this transformation (in kg)',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 70',
    validate: _weightValid,
    parse: (v) => double.parse(v),
    errMsg: 'Please enter a valid target weight (25–250 kg)',
  ),
  const AssessmentQuestion(
    field: 'transformation_goal',
    prompt: 'What is your primary transformation target?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '⬡', label: 'Six Pack Abs', value: 'six_pack'),
      AssessmentOption(icon: '🏆', label: 'Lean Physique / V-Taper', value: 'lean_physique'),
      AssessmentOption(icon: '🔄', label: 'Body Recomposition', value: 'recomposition'),
      AssessmentOption(icon: '✨', label: 'Aesthetic Physique', value: 'aesthetic'),
    ],
  ),
  AssessmentQuestion(
    field: 'goal_duration_months',
    prompt: 'What is your target transformation duration?',
    hint: 'Choose how long you want to commit to this transformation',
    type: AssessmentQuestionType.options,
    options: const [
      AssessmentOption(icon: '⚡', label: '1 Month', value: '1'),
      AssessmentOption(icon: '🔥', label: '2 Months', value: '2'),
      AssessmentOption(icon: '💪', label: '3 Months', value: '3'),
      AssessmentOption(icon: '🎯', label: '4 Months', value: '4'),
      AssessmentOption(icon: '🏆', label: '6 Months', value: '6'),
      AssessmentOption(icon: '⭐', label: '9 Months', value: '9'),
      AssessmentOption(icon: '👑', label: '12 Months', value: '12'),
    ],
    parse: (v) => int.parse(v),
  ),
  const AssessmentQuestion(
    field: 'workout_preference',
    prompt: 'Where will you train?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '🏋️', label: 'Gym (full equipment)', value: 'gym'),
      AssessmentOption(icon: '🏠', label: 'Home (bodyweight)', value: 'home'),
      AssessmentOption(icon: '🚶', label: 'Walking + bodyweight', value: 'walking'),
      AssessmentOption(icon: '❌', label: 'No equipment currently', value: 'none'),
    ],
  ),
  const AssessmentQuestion(
    field: 'available_time',
    prompt: 'How many days per week can you train?',
    hint: 'Transformation needs 4–5 sessions per week for best results',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '3️⃣', label: '3 days/week (minimum)', value: '30'),
      AssessmentOption(icon: '4️⃣', label: '4 days/week (good)', value: '45'),
      AssessmentOption(icon: '5️⃣', label: '5 days/week (great)', value: '60'),
      AssessmentOption(icon: '6️⃣', label: '6 days/week (elite)', value: '75'),
    ],
  ),
  const AssessmentQuestion(
    field: 'diet_preference',
    prompt: 'What type of food do you eat?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '🌿', label: 'Pure Vegetarian', value: 'vegetarian'),
      AssessmentOption(icon: '🍗', label: 'Non-Vegetarian', value: 'non-vegetarian'),
      AssessmentOption(icon: '🥚', label: 'Eggetarian (eggs only)', value: 'eggetarian'),
      AssessmentOption(icon: '🤷', label: 'No preference / Mixed', value: 'mixed'),
    ],
  ),
  const AssessmentQuestion(
    field: 'living_situation',
    prompt: 'Where do you eat most of your meals?',
    hint: 'This shapes your transformation meal plan',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '🏠', label: 'At Home (home-cooked)', value: 'home'),
      AssessmentOption(icon: '🏫', label: 'Hostel / PG', value: 'hostel'),
      AssessmentOption(icon: '🏢', label: 'Office / Rented room', value: 'pg'),
      AssessmentOption(icon: '🏟️', label: 'Sports Academy', value: 'other'),
    ],
  ),
  const AssessmentQuestion(
    field: 'activity_level',
    prompt: 'How active are you currently (outside workouts)?',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '🛋️', label: 'Mostly sitting (desk/student)', value: 'sedentary'),
      AssessmentOption(icon: '🚶', label: 'Light movement (walks, chores)', value: 'light'),
      AssessmentOption(icon: '🏃', label: 'Moderately active (3–4x/week)', value: 'moderate'),
      AssessmentOption(icon: '💪', label: 'Very active (daily exercise)', value: 'active'),
    ],
  ),
  AssessmentQuestion(
    field: 'sleep_hours',
    prompt: 'How many hours of sleep do you get per night?',
    hint: 'Sleep is critical for fat loss and visible abs — cortisol rises with poor sleep',
    type: AssessmentQuestionType.text,
    placeholder: 'e.g. 7',
    validate: _sleepValid,
    parse: (v) => double.parse(v),
    errMsg: 'Please enter 2–14 hours',
  ),
  const AssessmentQuestion(
    field: 'stress_level',
    prompt: 'How would you rate your daily stress level?',
    hint: '1 = very calm, 10 = extremely stressed (high stress = belly fat — impacts transformation)',
    type: AssessmentQuestionType.slider,
    min: 1,
    max: 10,
    defaultVal: 5,
  ),
  const AssessmentQuestion(
    field: 'budget',
    prompt: 'How much do you usually spend on food each day?',
    hint: 'Your transformation diet will be built to genuinely fit this',
    type: AssessmentQuestionType.options,
    options: [
      AssessmentOption(icon: '💰', label: '₹0–50 (hostel mess)', value: '₹50/day'),
      AssessmentOption(icon: '💰', label: '₹50–100', value: '₹100/day'),
      AssessmentOption(icon: '💰', label: '₹100–200', value: '₹150/day'),
      AssessmentOption(icon: '💰', label: '₹200+', value: '₹250/day'),
    ],
  ),
  supplementQuestion,
  _medicalConditionsQuestion,
];

List<AssessmentQuestion> questionsForGoal(String goal) {
  if (goal == 'general_fitness') return generalFitnessQuestions;
  if (goal == 'transformation') return transformationQuestions;
  return defaultQuestions;
}
