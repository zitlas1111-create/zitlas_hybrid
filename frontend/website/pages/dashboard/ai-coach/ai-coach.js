/* =============================================
   ZITLAS — AI Coach Onboarding  (ai-coach.js)
   11-step flow: Welcome → Goal → Assessment →
   Processing → Snapshot → SWOT → Diet →
   Workout → Sources → CTA → Done
   ============================================= */

(function () {
  'use strict';

  /* ══════════════════════════════════════════
     STATE
  ══════════════════════════════════════════ */
  var state = {
    answers:      {},            // assessment answers keyed by field
    apiResult:    null,          // full /generate-plan response
    currentQ:     0,             // current assessment question index
    selectedGoal: 'lose_weight', // goal card selection
  };

  var _wpCleanup = null; // cleanup fn for the active wheel picker

  /* ══════════════════════════════════════════
     ASSESSMENT QUESTIONS  (maps to AssessmentInput)
  ══════════════════════════════════════════ */

  /* Shared across all three assessment flows. One multiselect yields both
     backend fields: picking "I don't use supplements" → uses_supplements
     'no' (diet will NEVER suggest whey/creatine/etc.); picking products →
     'yes' + supplement_types. Derived in buildAssessmentPayload(). */
  var SUPPLEMENT_QUESTION = {
    field: 'supplements_used',
    prompt: 'Do you use any supplements?',
    hint: 'If you don’t, we’ll build your protein targets from whole foods only',
    type: 'multiselect',
    opts: [
      { label: '❌ I don’t use supplements', value: 'none' },
      { label: 'Whey Protein',  value: 'Whey Protein' },
      { label: 'Creatine',      value: 'Creatine' },
      { label: 'Multivitamin',  value: 'Multivitamin' },
      { label: 'Fish Oil',      value: 'Fish Oil' },
      { label: 'Vitamin D',     value: 'Vitamin D' },
      { label: 'BCAA',          value: 'BCAA' },
      { label: 'Mass Gainer',   value: 'Mass Gainer' },
      { label: 'Electrolytes',  value: 'Electrolytes' },
      { label: 'Other',         value: 'Other' },
    ],
  };

  var QUESTIONS = [
    {
      field: 'age',
      prompt: 'How old are you?',
      hint: 'Enter your age in years',
      type: 'text',
      placeholder: 'e.g. 22',
      validate: function (v) {
        var n = parseInt(v, 10);
        return !isNaN(n) && n >= 13 && n <= 100;
      },
      parse: function (v) { return parseInt(v, 10); },
      errMsg: 'Please enter a valid age (13–100)',
    },
    {
      field: 'gender',
      prompt: 'What is your gender?',
      type: 'options',
      opts: [
        { icon: '👨', label: 'Male',   value: 'male' },
        { icon: '👩', label: 'Female', value: 'female' },
        { icon: '🧑', label: 'Other',  value: 'other' },
      ],
    },
    {
      field: 'height_cm',
      prompt: 'How tall are you?',
      hint: 'Enter your height in centimetres (cm)',
      type: 'text',
      placeholder: 'e.g. 170',
      validate: function (v) {
        var n = parseFloat(v);
        return !isNaN(n) && n >= 120 && n <= 230;
      },
      parse: function (v) { return parseFloat(v); },
      errMsg: 'Please enter a valid height (120–230 cm)',
    },
    {
      field: 'weight_kg',
      prompt: 'What is your current weight?',
      hint: 'Enter your weight in kilograms (kg)',
      type: 'text',
      placeholder: 'e.g. 78',
      validate: function (v) {
        var n = parseFloat(v);
        return !isNaN(n) && n >= 25 && n <= 250;
      },
      parse: function (v) { return parseFloat(v); },
      errMsg: 'Please enter a valid weight (25–250 kg)',
    },
    {
      field: 'goal_weight_kg',
      prompt: 'What is your goal weight?',
      hint: 'The weight you want to reach (in kg)',
      type: 'text',
      placeholder: 'e.g. 65',
      validate: function (v) {
        var n = parseFloat(v);
        return !isNaN(n) && n >= 25 && n <= 250;
      },
      parse: function (v) { return parseFloat(v); },
      errMsg: 'Please enter a valid goal weight (25–250 kg)',
    },
    {
      field: 'activity_level',
      prompt: 'How active are you in daily life?',
      type: 'options',
      opts: [
        { icon: '🛋️', label: 'Mostly sitting (desk/student)', value: 'sedentary' },
        { icon: '🚶', label: 'Light activity (walks, chores)',  value: 'light' },
        { icon: '🏃', label: 'Moderate (3–4x exercise/week)',  value: 'moderate' },
        { icon: '💪', label: 'Very active (daily exercise)',    value: 'active' },
      ],
    },
    {
      field: 'diet_preference',
      prompt: 'What type of food do you eat?',
      type: 'options',
      opts: [
        { icon: '🌿', label: 'Pure Vegetarian',   value: 'vegetarian' },
        { icon: '🍗', label: 'Non-Vegetarian',    value: 'non-vegetarian' },
        { icon: '🥚', label: 'Eggetarian (eggs only, no meat)', value: 'eggetarian' },
        { icon: '🤷', label: 'Mixed / No preference', value: 'mixed' },
      ],
    },
    {
      field: 'living_situation',
      prompt: 'Where do you eat most of your meals?',
      hint: 'This shapes your entire meal plan',
      type: 'options',
      opts: [
        { icon: '🏠', label: 'At Home (home-cooked)',    value: 'home' },
        { icon: '🏫', label: 'Hostel / PG',              value: 'hostel' },
        { icon: '🏢', label: 'Office / Rented room',     value: 'pg' },
        { icon: '🏟️', label: 'Sports Academy / Camp',   value: 'other' },
      ],
    },
    {
      field: 'occupation',
      prompt: 'What best describes your occupation?',
      type: 'options',
      opts: [
        { icon: '📚', label: 'Student',           value: 'student' },
        { icon: '💼', label: 'Office Worker',     value: 'office_worker' },
        { icon: '🔧', label: 'Physical / Field Worker', value: 'physical_worker' },
        { icon: '🏠', label: 'Homemaker / Other', value: 'other' },
      ],
    },
    {
      field: 'workout_preference',
      prompt: 'What kind of workout can you do?',
      type: 'options',
      opts: [
        { icon: '🏠', label: 'Home workout (no equipment)', value: 'home' },
        { icon: '🏋️', label: 'Gym access',                 value: 'gym' },
        { icon: '🚶', label: 'Walking / Running only',      value: 'walking' },
        { icon: '❌', label: 'No workout currently',        value: 'none' },
      ],
    },
    {
      field: 'sleep_hours',
      prompt: 'How many hours of sleep do you get?',
      hint: 'Average hours per night',
      type: 'text',
      placeholder: 'e.g. 7',
      validate: function (v) {
        var n = parseFloat(v);
        return !isNaN(n) && n >= 2 && n <= 14;
      },
      parse: function (v) { return parseFloat(v); },
      errMsg: 'Please enter 2–14 hours',
    },
    {
      field: 'stress_level',
      prompt: 'How would you rate your daily stress level?',
      hint: '1 = very calm, 10 = extremely stressed',
      type: 'slider',
      min: 1,
      max: 10,
      defaultVal: 5,
    },
    {
      field: 'available_time',
      prompt: 'How much time can you realistically dedicate each day?',
      hint: 'Be honest — a 10-minute workout you actually do beats a 60-minute one you skip. We will never give you a longer workout than this.',
      type: 'text', // dispatches to the wheel picker via WHEEL_CONFIG.available_time — see renderQuestion()
      parse: function (v) { return parseInt(v, 10); },
    },
    {
      field: 'budget',
      prompt: 'How much do you usually spend on food each day?',
      hint: 'Your meal plan will be built to genuinely fit this — no fancy ingredients you can’t afford',
      type: 'options',
      opts: [
        { icon: '💰', label: '₹0–50 (hostel mess)',  value: '₹50/day' },
        { icon: '💰', label: '₹50–100',              value: '₹100/day' },
        { icon: '💰', label: '₹100–200',             value: '₹150/day' },
        { icon: '💰', label: '₹200+',                value: '₹250/day' },
      ],
    },
    SUPPLEMENT_QUESTION,
    {
      field: 'medical_conditions',
      prompt: 'Do you have any medical conditions?',
      hint: 'Type "none" if you don\'t have any',
      type: 'text',
      placeholder: 'e.g. diabetes, thyroid… or "none"',
      validate: function (v) { return v.trim().length > 0; },
      parse: function (v) {
        var s = v.trim().toLowerCase();
        return (s === 'none' || s === 'no' || s === 'n/a') ? 'none' : v.trim();
      },
      errMsg: 'Please enter a value or type "none"',
    },
  ];

  /* ══════════════════════════════════════════
     GENERAL FITNESS QUESTIONS  (14 questions)
  ══════════════════════════════════════════ */
  var GF_QUESTIONS = [
    // STEP 1: Basic Information
    {
      field: 'age', prompt: 'How old are you?', hint: 'Enter your age in years',
      type: 'text', placeholder: 'e.g. 22',
      validate: function (v) { var n = parseInt(v, 10); return !isNaN(n) && n >= 13 && n <= 100; },
      parse: function (v) { return parseInt(v, 10); }, errMsg: 'Please enter a valid age (13–100)',
    },
    {
      field: 'gender', prompt: 'What is your gender?', type: 'options',
      opts: [
        { icon: '👨', label: 'Male',   value: 'male' },
        { icon: '👩', label: 'Female', value: 'female' },
        { icon: '🧑', label: 'Other',  value: 'other' },
      ],
    },
    {
      field: 'height_cm', prompt: 'How tall are you?', hint: 'Enter your height in centimetres (cm)',
      type: 'text', placeholder: 'e.g. 170',
      validate: function (v) { var n = parseFloat(v); return !isNaN(n) && n >= 120 && n <= 230; },
      parse: function (v) { return parseFloat(v); }, errMsg: 'Please enter a valid height (120–230 cm)',
    },
    {
      field: 'weight_kg', prompt: 'What is your current weight?', hint: 'Enter your weight in kilograms (kg)',
      type: 'text', placeholder: 'e.g. 70',
      validate: function (v) { var n = parseFloat(v); return !isNaN(n) && n >= 25 && n <= 250; },
      parse: function (v) { return parseFloat(v); }, errMsg: 'Please enter a valid weight (25–250 kg)',
    },
    // STEP 2: Lifestyle Assessment
    {
      field: 'activity_level', prompt: 'How active are you in daily life?', type: 'options',
      opts: [
        { icon: '🛋️', label: 'Sedentary (mostly sitting)',        value: 'sedentary' },
        { icon: '🚶', label: 'Lightly Active (walks, chores)',    value: 'light' },
        { icon: '🏃', label: 'Moderately Active (3–4x/week)',     value: 'moderate' },
        { icon: '💪', label: 'Very Active (daily exercise)',       value: 'active' },
      ],
    },
    {
      field: 'occupation', prompt: 'What best describes your occupation?', type: 'options',
      opts: [
        { icon: '📚', label: 'Student',              value: 'student' },
        { icon: '💼', label: 'Working Professional', value: 'office_worker' },
        { icon: '🏢', label: 'Business Owner',       value: 'freelancer' },
        { icon: '🏠', label: 'Homemaker',            value: 'other' },
      ],
    },
    {
      field: 'living_situation', prompt: 'Where do you currently live?', type: 'options',
      opts: [
        { icon: '🏫', label: 'Hostel',       value: 'hostel' },
        { icon: '🏠', label: 'PG',           value: 'pg' },
        { icon: '🏡', label: 'Home',         value: 'home' },
        { icon: '🚪', label: 'Living Alone', value: 'rented' },
      ],
    },
    {
      field: 'diet_preference', prompt: 'What type of food do you eat?', type: 'options',
      opts: [
        { icon: '🌿', label: 'Pure Vegetarian',      value: 'vegetarian' },
        { icon: '🍗', label: 'Non-Vegetarian',       value: 'non-vegetarian' },
        { icon: '🥚', label: 'Eggetarian',           value: 'eggetarian' },
        { icon: '🤷', label: 'No preference / Mixed', value: 'mixed' },
      ],
    },
    // STEP 3: Health Goals (multi-select)
    {
      field: 'health_goals',
      prompt: 'What would you like to improve?',
      type: 'multiselect',
      opts: [
        { label: 'More Energy',         value: 'energy' },
        { label: 'Better Health',       value: 'health' },
        { label: 'Improve Fitness',     value: 'fitness' },
        { label: 'Build Healthy Habits',value: 'habits' },
        { label: 'Better Mobility',     value: 'mobility' },
        { label: 'Better Endurance',    value: 'endurance' },
        { label: 'Better Strength',     value: 'strength' },
        { label: 'Improve Posture',     value: 'posture' },
        { label: 'Reduce Stress',       value: 'reduce_stress' },
        { label: 'Better Sleep',        value: 'sleep' },
      ],
    },
    // STEP 4: Current Fitness Level
    {
      field: 'fitness_level', prompt: 'What is your current fitness level?', type: 'options',
      opts: [
        { icon: '🌱', label: 'Beginner — just starting out',         value: 'beginner' },
        { icon: '🔥', label: 'Intermediate — some exercise history', value: 'intermediate' },
        { icon: '⚡', label: 'Advanced — regular consistent training', value: 'advanced' },
      ],
    },
    // STEP 5: Workout Preference
    {
      field: 'workout_preference', prompt: 'What kind of workout do you prefer?', type: 'options',
      opts: [
        { icon: '🏠', label: 'Home Workout',  value: 'home' },
        { icon: '🏋️', label: 'Gym Workout',  value: 'gym' },
        { icon: '🚶', label: 'Walking',       value: 'walking' },
        { icon: '🔀', label: 'Mixed',         value: 'mixed' },
      ],
    },
    // STEP 6: Available Time
    {
      field: 'available_time',
      prompt: 'How much time can you realistically dedicate each day?',
      hint: 'Your workouts will never run longer than this',
      type: 'options',
      opts: [
        { icon: '⚡', label: '10 min', value: '10' },
        { icon: '🕐', label: '20 min', value: '20' },
        { icon: '🕑', label: '30 min', value: '30' },
        { icon: '🕒', label: '45 min', value: '45' },
        { icon: '🕓', label: '60+ min', value: '60' },
      ],
    },
    // STEP 7: Sleep
    {
      field: 'sleep_hours', prompt: 'How many hours of sleep do you get?', hint: 'Average hours per night',
      type: 'text', placeholder: 'e.g. 7',
      validate: function (v) { var n = parseFloat(v); return !isNaN(n) && n >= 2 && n <= 14; },
      parse: function (v) { return parseFloat(v); }, errMsg: 'Please enter 2–14 hours',
    },
    // STEP 8: Stress Level
    {
      field: 'stress_level', prompt: 'How would you rate your daily stress level?',
      hint: '1 = very calm, 10 = very stressed',
      type: 'slider', min: 1, max: 10, defaultVal: 5,
    },
    // STEP 9: Supplements
    SUPPLEMENT_QUESTION,
  ];

  /* ══════════════════════════════════════════
     TRANSFORMATION QUESTIONS  (8 questions)
  ══════════════════════════════════════════ */
  var TF_QUESTIONS = [
    // Basic biometrics
    {
      field: 'age', prompt: 'How old are you?', hint: 'Enter your age in years',
      type: 'text', placeholder: 'e.g. 22',
      validate: function (v) { var n = parseInt(v, 10); return !isNaN(n) && n >= 13 && n <= 100; },
      parse: function (v) { return parseInt(v, 10); }, errMsg: 'Please enter a valid age (13–100)',
    },
    {
      field: 'gender', prompt: 'What is your gender?', type: 'options',
      opts: [
        { icon: '👨', label: 'Male',   value: 'male' },
        { icon: '👩', label: 'Female', value: 'female' },
        { icon: '🧑', label: 'Other',  value: 'other' },
      ],
    },
    {
      field: 'height_cm', prompt: 'How tall are you?', hint: 'Height in centimetres (cm)',
      type: 'text', placeholder: 'e.g. 175',
      validate: function (v) { var n = parseFloat(v); return !isNaN(n) && n >= 120 && n <= 230; },
      parse: function (v) { return parseFloat(v); }, errMsg: 'Please enter a valid height (120–230 cm)',
    },
    {
      field: 'weight_kg', prompt: 'What is your current weight?', hint: 'Weight in kilograms (kg)',
      type: 'text', placeholder: 'e.g. 75',
      validate: function (v) { var n = parseFloat(v); return !isNaN(n) && n >= 25 && n <= 250; },
      parse: function (v) { return parseFloat(v); }, errMsg: 'Please enter a valid weight (25–250 kg)',
    },
    /* REQUIRED for a transformation: the plan is a current -> target
       trajectory, and this question was missing from TF_QUESTIONS entirely,
       so the calorie maths had no destination. Mirrors the Flutter
       transformation set field-for-field (same `goal_weight_kg` name, same
       25-250 kg validation) so both clients send an identical payload. */
    {
      field: 'goal_weight_kg', prompt: 'What is your target weight?',
      hint: 'The weight you want to reach through this transformation (in kg)',
      type: 'text', placeholder: 'e.g. 70',
      validate: function (v) { var n = parseFloat(v); return !isNaN(n) && n >= 25 && n <= 250; },
      parse: function (v) { return parseFloat(v); }, errMsg: 'Please enter a valid target weight (25–250 kg)',
    },
    // Transformation-specific questions
    {
      field: 'transformation_goal',
      prompt: 'What is your primary transformation target?',
      type: 'options',
      opts: [
        { icon: '⬡', label: 'Six Pack Abs',          value: 'six_pack' },
        { icon: '🏆', label: 'Lean Physique / V-Taper', value: 'lean_physique' },
        { icon: '🔄', label: 'Body Recomposition',    value: 'recomposition' },
        { icon: '✨', label: 'Aesthetic Physique',     value: 'aesthetic' },
      ],
    },
    {
      field: 'goal_duration_months',
      prompt: 'What is your target transformation duration?',
      hint: 'Choose how long you want to commit to this transformation',
      type: 'options',
      opts: [
        { icon: '⚡', label: '1 Month',   value: '1' },
        { icon: '🔥', label: '2 Months',  value: '2' },
        { icon: '💪', label: '3 Months',  value: '3' },
        { icon: '🎯', label: '4 Months',  value: '4' },
        { icon: '🏆', label: '6 Months',  value: '6' },
        { icon: '⭐', label: '9 Months',  value: '9' },
        { icon: '👑', label: '12 Months', value: '12' },
      ],
      parse: function (v) { return parseInt(v, 10); },
    },
    {
      field: 'workout_preference',
      prompt: 'Where will you train?',
      type: 'options',
      opts: [
        { icon: '🏋️', label: 'Gym (full equipment)',   value: 'gym' },
        { icon: '🏠', label: 'Home (bodyweight)',       value: 'home' },
        { icon: '🚶', label: 'Walking + bodyweight',   value: 'walking' },
        { icon: '❌', label: 'No equipment currently', value: 'none' },
      ],
    },
    {
      field: 'available_time',
      prompt: 'How many days per week can you train?',
      hint: 'Transformation needs 4–5 sessions per week for best results',
      type: 'options',
      opts: [
        { icon: '3️⃣', label: '3 days/week (minimum)', value: '30' },
        { icon: '4️⃣', label: '4 days/week (good)',    value: '45' },
        { icon: '5️⃣', label: '5 days/week (great)',   value: '60' },
        { icon: '6️⃣', label: '6 days/week (elite)',   value: '75' },
      ],
    },
    {
      field: 'diet_preference',
      prompt: 'What type of food do you eat?',
      type: 'options',
      opts: [
        { icon: '🌿', label: 'Pure Vegetarian',         value: 'vegetarian' },
        { icon: '🍗', label: 'Non-Vegetarian',          value: 'non-vegetarian' },
        { icon: '🥚', label: 'Eggetarian (eggs only)',  value: 'eggetarian' },
        { icon: '🤷', label: 'No preference / Mixed',   value: 'mixed' },
      ],
    },
    {
      field: 'living_situation',
      prompt: 'Where do you eat most of your meals?',
      hint: 'This shapes your transformation meal plan',
      type: 'options',
      opts: [
        { icon: '🏠', label: 'At Home (home-cooked)', value: 'home' },
        { icon: '🏫', label: 'Hostel / PG',           value: 'hostel' },
        { icon: '🏢', label: 'Office / Rented room',  value: 'pg' },
        { icon: '🏟️', label: 'Sports Academy',        value: 'other' },
      ],
    },
    {
      field: 'activity_level',
      prompt: 'How active are you currently (outside workouts)?',
      type: 'options',
      opts: [
        { icon: '🛋️', label: 'Mostly sitting (desk/student)', value: 'sedentary' },
        { icon: '🚶', label: 'Light movement (walks, chores)', value: 'light' },
        { icon: '🏃', label: 'Moderately active (3–4x/week)', value: 'moderate' },
        { icon: '💪', label: 'Very active (daily exercise)',   value: 'active' },
      ],
    },
    {
      field: 'sleep_hours',
      prompt: 'How many hours of sleep do you get per night?',
      hint: 'Sleep is critical for fat loss and visible abs — cortisol rises with poor sleep',
      type: 'text', placeholder: 'e.g. 7',
      validate: function (v) { var n = parseFloat(v); return !isNaN(n) && n >= 2 && n <= 14; },
      parse: function (v) { return parseFloat(v); }, errMsg: 'Please enter 2–14 hours',
    },
    {
      field: 'stress_level',
      prompt: 'How would you rate your daily stress level?',
      hint: '1 = very calm, 10 = extremely stressed (high stress = belly fat — impacts transformation)',
      type: 'slider', min: 1, max: 10, defaultVal: 5,
    },
    {
      field: 'budget',
      prompt: 'How much do you usually spend on food each day?',
      hint: 'Your transformation diet will be built to genuinely fit this',
      type: 'options',
      opts: [
        { icon: '💰', label: '₹0–50 (hostel mess)',  value: '₹50/day' },
        { icon: '💰', label: '₹50–100',              value: '₹100/day' },
        { icon: '💰', label: '₹100–200',             value: '₹150/day' },
        { icon: '💰', label: '₹200+',                value: '₹250/day' },
      ],
    },
    SUPPLEMENT_QUESTION,
    {
      field: 'medical_conditions',
      prompt: 'Do you have any medical conditions?',
      hint: 'Type "none" if you don\'t have any',
      type: 'text', placeholder: 'e.g. diabetes, thyroid… or "none"',
      validate: function (v) { return v.trim().length > 0; },
      parse: function (v) {
        var s = v.trim().toLowerCase();
        return (s === 'none' || s === 'no' || s === 'n/a') ? 'none' : v.trim();
      },
      errMsg: 'Please enter a value or type "none"',
    },
  ];

  function getActiveQuestions() {
    if (state.selectedGoal === 'general_fitness') return GF_QUESTIONS;
    if (state.selectedGoal === 'transformation')  return TF_QUESTIONS;
    return QUESTIONS;
  }

  /* ══════════════════════════════════════════
     WHEEL PICKER CONFIG
  ══════════════════════════════════════════ */
  var WHEEL_CONFIG = {
    age:            { min: 13,  max: 100, unit: 'years', defaultVal: 22  },
    height_cm:      { min: 120, max: 230, unit: 'cm',    defaultVal: 170 },
    weight_kg:      { min: 25,  max: 250, unit: 'kg',    defaultVal: 70  },
    goal_weight_kg: { min: 25,  max: 250, unit: 'kg',    defaultVal: 65  },
    sleep_hours:    { min: 4,   max: 12,  unit: 'hours', defaultVal: 8   },
    /* Discrete presets, not a contiguous range — replaces the free-text
       minutes input. Stored as the same plain integer minutes value
       (q.parse below), so AssessmentInput.available_time is unaffected. */
    available_time: { values: [5, 10, 15, 20, 25, 30, 45, 60, 75, 90], unit: 'min', defaultVal: 30 },
  };

  /* ══════════════════════════════════════════
     WHEEL PICKER FACTORY
     opts: { min, max, unit, value, defaultVal, onChange }
     returns: { el, getValue, cleanup }
  ══════════════════════════════════════════ */
  function createWheelPicker(opts) {
    var ITEM_H      = 56;
    var PADDING     = ITEM_H * 2; // 112 — centering space above/below list

    /* opts.values: explicit discrete list (e.g. [5,10,15,...,90] duration
       presets) — arbitrary spacing, unlike the contiguous min..max ranges
       height/weight use. When absent, behavior is 100% unchanged: a
       contiguous integer range from min to max. */
    var values      = Array.isArray(opts.values) ? opts.values.slice() : null;
    var min         = opts.min;
    var max         = opts.max;
    var unit        = opts.unit || '';
    var count       = values ? values.length : (max - min + 1);

    function indexToValue(idx) { return values ? values[idx] : (min + idx); }
    function valueToIndex(val) {
      if (!values) return val - min;
      var closest = 0, bestDiff = Infinity;
      for (var vi = 0; vi < values.length; vi++) {
        var diff = Math.abs(values[vi] - val);
        if (diff < bestDiff) { bestDiff = diff; closest = vi; }
      }
      return closest;
    }

    var initVal = (opts.value !== undefined && (values ? values.indexOf(Math.round(opts.value)) !== -1 : (opts.value >= min && opts.value <= max)))
      ? Math.round(opts.value)
      : (opts.defaultVal !== undefined ? opts.defaultVal : (values ? values[0] : min));
    var currentIndex = valueToIndex(initVal);
    var scrollY      = currentIndex * ITEM_H;

    /* ── Build DOM ── */
    var wrap       = document.createElement('div');
    wrap.className = 'wheel-picker-wrap';

    var picker       = document.createElement('div');
    picker.className = 'wheel-picker';
    picker.setAttribute('tabindex', '0');
    picker.setAttribute('role', 'spinbutton');
    picker.setAttribute('aria-valuemin', String(values ? values[0] : min));
    picker.setAttribute('aria-valuemax', String(values ? values[values.length - 1] : max));
    picker.setAttribute('aria-valuenow', String(initVal));

    var fadeTop       = document.createElement('div');
    fadeTop.className = 'wheel-fade-top';

    var fadeBot       = document.createElement('div');
    fadeBot.className = 'wheel-fade-bottom';

    var selZone       = document.createElement('div');
    selZone.className = 'wheel-selected-zone';

    var unitLbl       = document.createElement('span');
    unitLbl.className = 'wheel-unit-label';
    unitLbl.textContent = unit;

    var itemsCont       = document.createElement('div');
    itemsCont.className = 'wheel-items-container';

    var spacerTop = document.createElement('div');
    spacerTop.style.height = PADDING + 'px';
    itemsCont.appendChild(spacerTop);

    var itemEls = [];
    for (var i = 0; i < count; i++) {
      var el       = document.createElement('div');
      el.className = 'wheel-item';
      el.textContent = String(indexToValue(i));
      itemEls.push(el);
      itemsCont.appendChild(el);
    }

    var spacerBot = document.createElement('div');
    spacerBot.style.height = PADDING + 'px';
    itemsCont.appendChild(spacerBot);

    picker.appendChild(fadeTop);
    picker.appendChild(fadeBot);
    picker.appendChild(selZone);
    picker.appendChild(unitLbl);
    picker.appendChild(itemsCont);

    var kbHint       = document.createElement('div');
    kbHint.className = 'wheel-kb-hint';
    kbHint.textContent = '↑ ↓  arrow keys  ·  scroll  ·  drag';
    wrap.appendChild(picker);
    wrap.appendChild(kbHint);

    /* ── Render helpers ── */
    function clampY(y) { return Math.max(0, Math.min(y, (count - 1) * ITEM_H)); }

    function applyScroll() {
      itemsCont.style.transform = 'translateY(' + (-scrollY) + 'px)';
      var cx = scrollY / ITEM_H;
      for (var j = 0; j < itemEls.length; j++) {
        var d   = Math.abs(j - cx);
        var iel = itemEls[j];
        if (d < 0.55) {
          iel.style.fontSize   = '32px';
          iel.style.fontWeight = '800';
          iel.style.color      = 'var(--primary)';
          iel.style.opacity    = '1';
          iel.style.transform  = 'scale(1)';
        } else if (d < 1.55) {
          var t = (d - 0.55) / 1.0;
          iel.style.fontSize   = (32 - 12 * t).toFixed(1) + 'px';
          iel.style.fontWeight = '600';
          iel.style.color      = 'rgba(var(--white-rgb),' + (0.65 - 0.28 * t).toFixed(2) + ')';
          iel.style.opacity    = (1 - 0.38 * t).toFixed(2);
          iel.style.transform  = 'scale(' + (1 - 0.07 * t).toFixed(3) + ')';
        } else if (d < 2.55) {
          var t = (d - 1.55);
          iel.style.fontSize   = '18px';
          iel.style.fontWeight = '500';
          iel.style.color      = 'rgba(var(--white-rgb),' + (0.32 - 0.14 * t).toFixed(2) + ')';
          iel.style.opacity    = (0.62 - 0.28 * t).toFixed(2);
          iel.style.transform  = 'scale(0.87)';
        } else {
          iel.style.fontSize   = '15px';
          iel.style.fontWeight = '400';
          iel.style.color      = 'rgba(var(--white-rgb),0.10)';
          iel.style.opacity    = '0.35';
          iel.style.transform  = 'scale(0.80)';
        }
      }
      currentIndex = Math.round(scrollY / ITEM_H);
      picker.setAttribute('aria-valuenow', String(indexToValue(currentIndex)));
    }

    function snapTo(idx, animated) {
      idx = Math.max(0, Math.min(idx, count - 1));
      var target = idx * ITEM_H;
      if (!animated || Math.abs(target - scrollY) < 1) {
        scrollY = target;
        currentIndex = idx;
        applyScroll();
        if (opts.onChange) opts.onChange(indexToValue(idx));
        return;
      }
      var start = scrollY;
      var delta = target - start;
      var dur   = Math.min(320, Math.max(80, Math.abs(delta) * 1.4));
      var t0    = null;
      function step(ts) {
        if (!t0) t0 = ts;
        var progress = Math.min((ts - t0) / dur, 1);
        var eased    = 1 - Math.pow(1 - progress, 3);
        scrollY      = start + delta * eased;
        applyScroll();
        if (progress < 1) {
          requestAnimationFrame(step);
        } else {
          scrollY      = target;
          currentIndex = idx;
          applyScroll();
          if (opts.onChange) opts.onChange(indexToValue(idx));
        }
      }
      requestAnimationFrame(step);
    }

    /* ── Touch ── */
    var tStartY = 0, tStartSY = 0, tLastY = 0, tLastT = 0, tVel = 0;

    function onTouchStart(e) {
      tStartY  = e.touches[0].clientY;
      tStartSY = scrollY;
      tLastY   = tStartY;
      tLastT   = Date.now();
      tVel     = 0;
      e.preventDefault();
    }
    function onTouchMove(e) {
      var y   = e.touches[0].clientY;
      var now = Date.now();
      var dt  = now - tLastT;
      if (dt > 0) tVel = (tLastY - y) / dt;
      tLastY  = y;
      tLastT  = now;
      scrollY = clampY(tStartSY + (tStartY - y));
      applyScroll();
      e.preventDefault();
    }
    function onTouchEnd() {
      var momentum = tVel * 130;
      snapTo(Math.round((scrollY + momentum) / ITEM_H), true);
    }
    picker.addEventListener('touchstart', onTouchStart, { passive: false });
    picker.addEventListener('touchmove',  onTouchMove,  { passive: false });
    picker.addEventListener('touchend',   onTouchEnd);

    /* ── Mouse drag ── */
    var mDown = false, mStartY = 0, mStartSY = 0, mLastY = 0, mLastT = 0, mVel = 0;

    function onMouseDown(e) {
      mDown    = true;
      mStartY  = e.clientY;
      mStartSY = scrollY;
      mLastY   = mStartY;
      mLastT   = Date.now();
      mVel     = 0;
      picker.classList.add('is-grabbing');
      e.preventDefault();
    }
    function onMouseMove(e) {
      if (!mDown) return;
      var now = Date.now(), dt = now - mLastT;
      if (dt > 0) mVel = (mLastY - e.clientY) / dt;
      mLastY  = e.clientY;
      mLastT  = now;
      scrollY = clampY(mStartSY + (mStartY - e.clientY));
      applyScroll();
    }
    function onMouseUp() {
      if (!mDown) return;
      mDown = false;
      picker.classList.remove('is-grabbing');
      snapTo(Math.round((scrollY + mVel * 130) / ITEM_H), true);
    }
    picker.addEventListener('mousedown', onMouseDown);
    document.addEventListener('mousemove', onMouseMove);
    document.addEventListener('mouseup',   onMouseUp);

    /* ── Mouse wheel ── */
    var wTimer = null;
    picker.addEventListener('wheel', function(e) {
      e.preventDefault();
      scrollY = clampY(scrollY + e.deltaY * 0.55);
      applyScroll();
      clearTimeout(wTimer);
      wTimer = setTimeout(function() {
        snapTo(Math.round(scrollY / ITEM_H), true);
      }, 150);
    }, { passive: false });

    /* ── Keyboard ── */
    picker.addEventListener('keydown', function(e) {
      if (e.key === 'ArrowDown' || e.key === 'ArrowRight') {
        snapTo(currentIndex + 1, true); e.preventDefault();
      } else if (e.key === 'ArrowUp' || e.key === 'ArrowLeft') {
        snapTo(currentIndex - 1, true); e.preventDefault();
      }
    });

    /* ── Initial render ── */
    applyScroll();

    return {
      el:       wrap,
      getValue: function() { return indexToValue(currentIndex); },
      cleanup:  function() {
        document.removeEventListener('mousemove', onMouseMove);
        document.removeEventListener('mouseup',   onMouseUp);
        clearTimeout(wTimer);
      },
    };
  }

  /* ══════════════════════════════════════════
     UNIT CONVERSION HELPERS
  ══════════════════════════════════════════ */
  function cmToFtIn(cm) {
    var totalIn = cm / 2.54;
    var ft      = Math.floor(totalIn / 12);
    var inches  = Math.round(totalIn - ft * 12);
    if (inches === 12) { ft++; inches = 0; }
    return { ft: Math.max(3, Math.min(8, ft)), inches: Math.max(0, Math.min(11, inches)) };
  }
  function ftInToCm(ft, inches) { return Math.round(ft * 30.48 + inches * 2.54); }
  function kgToLbs(kg)          { return Math.round(kg * 2.20462); }
  function lbsToKg(lbs)         { return Math.round(lbs * 0.45359237 * 10) / 10; }

  /* ══════════════════════════════════════════
     HEIGHT WHEEL PICKER (CM / FT+IN toggle)
  ══════════════════════════════════════════ */
  function mountHeightPicker(mount, contBtn) {
    var wpRef = null;

    function getInitCm() {
      var v = state.answers.height_cm;
      var cfg = WHEEL_CONFIG.height_cm;
      return (v !== undefined && v >= cfg.min && v <= cfg.max) ? Math.round(v) : cfg.defaultVal;
    }

    function applyUnit(unit) {
      if (wpRef) { wpRef.cleanup(); }
      mount.innerHTML = '';

      if (unit === 'cm') {
        var cfg = WHEEL_CONFIG.height_cm;
        var wp  = createWheelPicker({ min: cfg.min, max: cfg.max, unit: 'cm',
          value: getInitCm(), defaultVal: cfg.defaultVal });
        wpRef = { getValue: wp.getValue, cleanup: wp.cleanup };
        mount.appendChild(wp.el);
        wp.el.querySelector('.wheel-picker').focus();
      } else {
        var cv      = cmToFtIn(getInitCm());
        var dualRow = document.createElement('div');
        dualRow.className = 'wheel-dual-row';
        var wpFt = createWheelPicker({ min: 3, max: 8,  unit: 'ft', value: cv.ft,     defaultVal: 5 });
        var wpIn = createWheelPicker({ min: 0, max: 11, unit: 'in', value: cv.inches, defaultVal: 7 });
        dualRow.appendChild(wpFt.el);
        dualRow.appendChild(wpIn.el);
        mount.appendChild(dualRow);
        wpRef = {
          getValue: function () { return ftInToCm(wpFt.getValue(), wpIn.getValue()); },
          cleanup:  function () { wpFt.cleanup(); wpIn.cleanup(); },
        };
        wpFt.el.querySelector('.wheel-picker').focus();
      }
      _wpCleanup = wpRef.cleanup;
    }

    mount.parentNode.querySelectorAll('.unit-btn').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var unit = btn.dataset.unit;
        mount.parentNode.querySelectorAll('.unit-btn').forEach(function (b) { b.classList.remove('active'); });
        btn.classList.add('active');
        if (wpRef) state.answers.height_cm = wpRef.getValue();
        state.answers.preferred_height_unit = unit;
        applyUnit(unit);
      });
    });

    applyUnit(state.answers.preferred_height_unit || 'cm');

    if (contBtn) {
      contBtn.addEventListener('click', function () {
        state.answers.height_cm = wpRef ? wpRef.getValue() : WHEEL_CONFIG.height_cm.defaultVal;
        state.answers.preferred_height_unit = state.answers.preferred_height_unit || 'cm';
        advanceQuestion();
      });
    }
  }

  /* ══════════════════════════════════════════
     WEIGHT WHEEL PICKER (KG / LBS toggle)
  ══════════════════════════════════════════ */
  function mountWeightPicker(mount, contBtn, field) {
    var cfg   = WHEEL_CONFIG[field];
    var wpRef = null;

    function getInitKg() {
      var v = state.answers[field];
      return (v !== undefined && v >= cfg.min && v <= cfg.max) ? Math.round(v) : cfg.defaultVal;
    }

    function applyUnit(unit) {
      if (wpRef) { wpRef.cleanup(); }
      mount.innerHTML = '';

      if (unit === 'kg') {
        var wp = createWheelPicker({ min: cfg.min, max: cfg.max, unit: 'kg',
          value: getInitKg(), defaultVal: cfg.defaultVal });
        wpRef = { getValue: wp.getValue, cleanup: wp.cleanup };
        mount.appendChild(wp.el);
        wp.el.querySelector('.wheel-picker').focus();
      } else {
        var minLbs = kgToLbs(cfg.min), maxLbs = kgToLbs(cfg.max), defLbs = kgToLbs(cfg.defaultVal);
        var wp = createWheelPicker({ min: minLbs, max: maxLbs, unit: 'lbs',
          value: kgToLbs(getInitKg()), defaultVal: defLbs });
        wpRef = {
          getValue: function () { return lbsToKg(wp.getValue()); },
          cleanup:  wp.cleanup,
        };
        mount.appendChild(wp.el);
        wp.el.querySelector('.wheel-picker').focus();
      }
      _wpCleanup = wpRef.cleanup;
    }

    mount.parentNode.querySelectorAll('.unit-btn').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var unit = btn.dataset.unit;
        mount.parentNode.querySelectorAll('.unit-btn').forEach(function (b) { b.classList.remove('active'); });
        btn.classList.add('active');
        if (wpRef) state.answers[field] = wpRef.getValue();
        state.answers.preferred_weight_unit = unit;
        applyUnit(unit);
      });
    });

    applyUnit(state.answers.preferred_weight_unit || 'kg');

    if (contBtn) {
      contBtn.addEventListener('click', function () {
        state.answers[field] = wpRef ? wpRef.getValue() : cfg.defaultVal;
        state.answers.preferred_weight_unit = state.answers.preferred_weight_unit || 'kg';
        advanceQuestion();
      });
    }
  }

  /* ══════════════════════════════════════════
     PROCESSING STEPS (shown during API call)
  ══════════════════════════════════════════ */
  var PROC_STEPS = [
    { icon: '📋', label: 'Analyzing your profile…' },
    { icon: '⚖️', label: 'Calculating BMI & BMR…' },
    { icon: '🔥', label: 'Computing calorie targets…' },
    { icon: '🧠', label: 'Building SWOT profile…' },
    { icon: '📚', label: 'Searching research database…' },
    { icon: '🥗', label: 'Generating your diet plan…' },
    { icon: '💪', label: 'Creating workout program…' },
    { icon: '✨', label: 'Finalizing recommendations…' },
  ];

  /* ══════════════════════════════════════════
     SCREEN NAVIGATION
  ══════════════════════════════════════════ */
  function showScreen(id) {
    document.querySelectorAll('.screen').forEach(function (el) {
      el.classList.remove('active');
      el.style.display = '';
    });
    var target = document.getElementById(id);
    if (target) {
      target.classList.add('active');
      window.scrollTo(0, 0);
    }
  }

  /* ══════════════════════════════════════════
     ASSESSMENT RENDERING
  ══════════════════════════════════════════ */
  function renderQuestion(idx) {
    if (_wpCleanup) { _wpCleanup(); _wpCleanup = null; }

    var qs  = getActiveQuestions();
    var q   = qs[idx];
    if (!q) return;

    var total = qs.length;
    var pct   = Math.round((idx / total) * 100);

    var label = document.getElementById('assessQLabel');
    var fill  = document.getElementById('assessFill');
    if (label) label.textContent = 'Question ' + (idx + 1) + ' of ' + total;
    if (fill)  fill.style.width = pct + '%';

    var body = document.getElementById('assessBody');
    if (!body) return;

    var html = '<div class="q-card"><p class="q-prompt">' + esc(q.prompt) + '</p>';
    if (q.hint) html += '<p class="q-hint">' + esc(q.hint) + '</p>';

    if (q.type === 'options') {
      html += '<p class="q-select-hint">Select one option</p>';
      html += '<div class="q-options">';
      q.opts.forEach(function (opt) {
        html += '<button class="q-opt" data-value="' + esc(opt.value) + '">' +
          (opt.icon ? '<span class="q-opt-icon">' + opt.icon + '</span>' : '') +
          '<span>' + esc(opt.label) + '</span>' +
          '</button>';
      });
      html += '</div>';
    } else if (q.type === 'multiselect') {
      html += '<p class="q-select-hint">Select all that apply</p>';
      html += '<div class="q-multiselect">';
      q.opts.forEach(function (opt) {
        html += '<button class="q-ms-opt" data-value="' + esc(opt.value) + '">' +
          esc(opt.label) + '</button>';
      });
      html += '</div>';
      html += '<p class="q-hint" id="qMsErr" style="color:var(--primary-dark);display:none">Please select at least one option</p>';
      html += '<button class="q-continue-btn" id="qContinueBtn" style="margin-top:16px">Continue →</button>';
    } else if (q.type === 'slider') {
      var def = (state.answers[q.field] !== undefined) ? state.answers[q.field] : q.defaultVal;
      html += '<div class="q-slider-val" id="sliderVal">' + def + '</div>' +
        '<div class="q-slider-wrap">' +
        '<input type="range" class="q-slider" id="sliderInput" ' +
        'min="' + q.min + '" max="' + q.max + '" value="' + def + '" />' +
        '<div class="q-slider-labels"><span>' + q.min + ' (calm)</span><span>' + q.max + ' (stressed)</span></div>' +
        '</div>' +
        '<button class="q-continue-btn" id="qContinueBtn">Continue →</button>';
    } else if (q.field === 'height_cm') {
      var hUnit = state.answers.preferred_height_unit || 'cm';
      html += '<div class="unit-toggle">' +
        '<button class="unit-btn' + (hUnit === 'cm'   ? ' active' : '') + '" data-unit="cm">CM</button>' +
        '<button class="unit-btn' + (hUnit !== 'cm'   ? ' active' : '') + '" data-unit="ftin">FT / IN</button>' +
        '</div><div id="unitPickerMount"></div>' +
        '<button class="q-continue-btn" id="qContinueBtn" style="margin-top:20px">Continue →</button>';
    } else if (q.field === 'weight_kg' || q.field === 'goal_weight_kg') {
      var wUnit = state.answers.preferred_weight_unit || 'kg';
      html += '<div class="unit-toggle">' +
        '<button class="unit-btn' + (wUnit === 'kg'   ? ' active' : '') + '" data-unit="kg">KG</button>' +
        '<button class="unit-btn' + (wUnit !== 'kg'   ? ' active' : '') + '" data-unit="lbs">LBS</button>' +
        '</div><div id="unitPickerMount"></div>' +
        '<button class="q-continue-btn" id="qContinueBtn" style="margin-top:20px">Continue →</button>';
    } else if (WHEEL_CONFIG[q.field]) {
      // Wheel picker — actual component mounted after innerHTML is set
      html += '<div id="wheelPickerMount"></div>' +
        '<button class="q-continue-btn" id="qContinueBtn" style="margin-top:20px">Continue →</button>';
    } else {
      var existingVal = state.answers[q.field] !== undefined ? state.answers[q.field] : '';
      html += '<input type="text" ' +
        'class="q-text-input" id="qTextInput" ' +
        'placeholder="' + esc(q.placeholder || '') + '" ' +
        'value="' + esc(String(existingVal)) + '" />' +
        '<p class="q-hint" id="qErrMsg" style="color:var(--primary-dark);display:none">' + esc(q.errMsg || '') + '</p>' +
        '<button class="q-continue-btn" id="qContinueBtn">Continue →</button>';
    }

    html += '</div>';
    body.innerHTML = html;

    // Mount unit-toggle pickers for height and weight
    if (q.field === 'height_cm') {
      var uMount = document.getElementById('unitPickerMount');
      var uBtn   = document.getElementById('qContinueBtn');
      if (uMount) mountHeightPicker(uMount, uBtn);
    } else if (q.field === 'weight_kg' || q.field === 'goal_weight_kg') {
      var uMount = document.getElementById('unitPickerMount');
      var uBtn   = document.getElementById('qContinueBtn');
      if (uMount) mountWeightPicker(uMount, uBtn, q.field);
    }

    // Mount wheel picker for other numeric wheel fields
    if (q.type === 'text' && WHEEL_CONFIG[q.field] && q.field !== 'height_cm' && q.field !== 'weight_kg' && q.field !== 'goal_weight_kg') {
      var wcfg    = WHEEL_CONFIG[q.field];
      var initVal = state.answers[q.field] !== undefined ? state.answers[q.field] : wcfg.defaultVal;
      var wp      = createWheelPicker({
        min: wcfg.min, max: wcfg.max, unit: wcfg.unit, values: wcfg.values,
        value: initVal, defaultVal: wcfg.defaultVal,
      });
      _wpCleanup = wp.cleanup;
      var mount  = document.getElementById('wheelPickerMount');
      if (mount) mount.parentNode.replaceChild(wp.el, mount);
      var wpBtn  = document.getElementById('qContinueBtn');
      if (wpBtn) {
        wpBtn.addEventListener('click', function() {
          var val = wp.getValue();
          state.answers[q.field] = q.parse ? q.parse(String(val)) : val;
          advanceQuestion();
        });
      }
      wp.el.querySelector('.wheel-picker').focus();
    }

    // Bind option buttons
    if (q.type === 'options') {
      body.querySelectorAll('.q-opt').forEach(function (btn) {
        btn.addEventListener('click', function () {
          body.querySelectorAll('.q-opt').forEach(function (b) { b.classList.remove('chosen'); b.disabled = true; });
          btn.classList.add('chosen');
          var val = btn.dataset.value;
          state.answers[q.field] = val;
          setTimeout(function () { advanceQuestion(); }, 320);
        });
      });
    }

    // Multi-select (health goals)
    if (q.type === 'multiselect') {
      var selected = Array.isArray(state.answers[q.field]) ? state.answers[q.field].slice() : [];
      body.querySelectorAll('.q-ms-opt').forEach(function (btn) {
        var val = btn.dataset.value;
        if (selected.indexOf(val) !== -1) btn.classList.add('chosen');
        btn.addEventListener('click', function () {
          if (btn.classList.contains('chosen')) {
            btn.classList.remove('chosen');
            selected = selected.filter(function (v) { return v !== val; });
          } else {
            btn.classList.add('chosen');
            selected.push(val);
          }
          state.answers[q.field] = selected;
          var errEl = document.getElementById('qMsErr');
          if (errEl && selected.length > 0) errEl.style.display = 'none';
        });
      });
      var msContBtn = document.getElementById('qContinueBtn');
      if (msContBtn) {
        msContBtn.addEventListener('click', function () {
          if (selected.length === 0) {
            var errEl = document.getElementById('qMsErr');
            if (errEl) errEl.style.display = 'block';
            return;
          }
          state.answers[q.field] = selected;
          advanceQuestion();
        });
      }
    }

    // Slider
    if (q.type === 'slider') {
      var sliderEl = document.getElementById('sliderInput');
      var valEl    = document.getElementById('sliderVal');
      if (sliderEl && valEl) {
        sliderEl.addEventListener('input', function () {
          valEl.textContent = sliderEl.value;
          updateSliderBg(sliderEl);
        });
        updateSliderBg(sliderEl);
      }
      var contBtn = document.getElementById('qContinueBtn');
      if (contBtn) {
        contBtn.addEventListener('click', function () {
          state.answers[q.field] = parseInt(sliderEl ? sliderEl.value : q.defaultVal, 10);
          advanceQuestion();
        });
      }
    }

    // Text input (plain fields only — wheel fields are handled above)
    if (q.type === 'text' && !WHEEL_CONFIG[q.field]) {
      var textEl = document.getElementById('qTextInput');
      var contBtn = document.getElementById('qContinueBtn');
      var errEl   = document.getElementById('qErrMsg');

      if (textEl) setTimeout(function () { textEl.focus(); }, 100);

      function submit() {
        var raw = textEl ? textEl.value.trim() : '';
        var valid = !q.validate || q.validate(raw);
        if (!valid) {
          if (errEl) errEl.style.display = 'block';
          if (textEl) textEl.style.borderColor = 'var(--primary-dark)';
          return;
        }
        state.answers[q.field] = q.parse ? q.parse(raw) : raw;
        advanceQuestion();
      }

      if (contBtn) contBtn.addEventListener('click', submit);
      if (textEl) {
        textEl.addEventListener('keydown', function (e) {
          if (e.key === 'Enter') submit();
        });
        textEl.addEventListener('input', function () {
          if (errEl) errEl.style.display = 'none';
          textEl.style.borderColor = '';
        });
      }
    }
  }

  function updateSliderBg(el) {
    var pct = ((el.value - el.min) / (el.max - el.min)) * 100;
    el.style.background = 'linear-gradient(to right, var(--accent) 0%, var(--accent) ' + pct + '%, rgba(var(--white-rgb),0.1) ' + pct + '%, rgba(var(--white-rgb),0.1) 100%)';
  }

  function advanceQuestion() {
    state.currentQ++;
    var qs = getActiveQuestions();
    if (state.currentQ >= qs.length) {
      startProcessing();
    } else {
      renderQuestion(state.currentQ);
    }
  }

  /* ══════════════════════════════════════════
     PROCESSING + API CALL
  ══════════════════════════════════════════ */
  function startProcessing() {
    showScreen('s-processing');
    renderProcSteps();
    callGeneratePlan();
  }

  function renderProcSteps() {
    var container = document.getElementById('procSteps');
    if (!container) return;
    container.innerHTML = PROC_STEPS.map(function (s, i) {
      return '<div class="proc-step" id="ps' + i + '">' +
        '<span class="proc-step-icon">' + s.icon + '</span>' +
        '<span class="proc-step-label">' + s.label + '</span>' +
        '<span class="proc-step-tick">✓</span>' +
        '</div>';
    }).join('');

    PROC_STEPS.forEach(function (_, i) {
      var delay = i * 800;
      setTimeout(function () {
        var el = document.getElementById('ps' + i);
        if (el) el.classList.add('visible');
      }, delay);
      setTimeout(function () {
        var el = document.getElementById('ps' + i);
        if (el) el.classList.add('done');
      }, delay + 550);
    });
  }

  function callGeneratePlan() {
    var payload = buildPayload();
    var minWait = PROC_STEPS.length * 800 + 600;
    var apiDone = false;
    var timerDone = false;
    var apiData = null;

    function tryAdvance() {
      if (apiDone && timerDone) {
        if (apiData) {
          state.apiResult = apiData;
          saveToLocalStorage(apiData);
          showScreen('s-snapshot');
          renderSnapshot(apiData.calculations);
        } else {
          showScreen('s-snapshot');
          renderSnapshot(null);
        }
      }
    }

    setTimeout(function () { timerDone = true; tryAdvance(); }, minWait);

    fetch('/api/assessment/generate-plan', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(payload),
    })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (data) {
        apiData = data;
        apiDone = true;
        tryAdvance();
      })
      .catch(function () {
        apiDone = true;
        tryAdvance();
      });
  }

  function buildPayload() {
    var a                = state.answers;
    var isGF             = state.selectedGoal === 'general_fitness';
    var isMuscle         = state.selectedGoal === 'muscle_gain';
    var isTransformation = state.selectedGoal === 'transformation';
    var fitnessGoal = (
      isMuscle         ? 'muscle_gain'    :
      isGF             ? 'general_fitness':
      isTransformation ? 'transformation' :
      'weight_loss'
    );

    /* General fitness genuinely has no target-weight question, so it stays at
       current weight (maintenance). TRANSFORMATION now ASKS for a target and
       must forward it — it previously overwrote the answer with the current
       weight, which is why a transformation plan had no trajectory to build a
       calorie target around. Falls back to current weight so a payload from an
       older client that never asked the question behaves exactly as before. */
    var goalWeight = isGF
      ? (a.weight_kg || 70)
      : isTransformation
        ? (a.goal_weight_kg || a.weight_kg || 70)
        : (a.goal_weight_kg || 65);

    return {
      age:               a.age               || 22,
      gender:            a.gender            || 'other',
      height_cm:         a.height_cm         || 170,
      weight_kg:         a.weight_kg         || 75,
      goal_weight_kg:    goalWeight,
      activity_level:    a.activity_level    || 'sedentary',
      occupation:        a.occupation        || 'other',
      living_situation:  a.living_situation  || 'home',
      diet_preference:   a.diet_preference   || 'mixed',
      workout_preference:a.workout_preference|| 'home',
      sleep_hours:       a.sleep_hours       || 7,
      stress_level:      a.stress_level      || 5,
      available_time:    parseInt(a.available_time, 10) || 30,
      budget:            a.budget            || '',
      medical_conditions:a.medical_conditions|| 'none',
      fitness_goal:      fitnessGoal,
      // General fitness specific fields
      health_goals:      Array.isArray(a.health_goals) ? a.health_goals : [],
      fitness_level:     a.fitness_level     || 'beginner',
      // Transformation specific fields
      goal_duration_months: parseInt(a.goal_duration_months, 10) || null,
      transformation_goal:  a.transformation_goal || null,
      // Supplement preference — one multiselect answer becomes both fields.
      // Empty/unanswered → '' (backend treats as "not asked", old behavior).
      uses_supplements:  _supplementsUsed(a).uses,
      supplement_types:  _supplementsUsed(a).types,
      // Preference memory (#13): exercises/foods the user repeatedly skips.
      // Nothing writes these keys yet — the backend excludes them when present.
      disliked_exercises: _prefList('zitlas_skipped_exercises'),
      disliked_foods:     _prefList('zitlas_disliked_foods'),
      // Geo-Aware Food Intelligence: optional, only present once the user
      // has granted location permission (see assets/js/geo-location.js).
      // Absent -> {} -> backend behaves exactly as before.
      location: _savedLocation(),
    };
  }

  function _savedLocation() {
    try {
      var v = JSON.parse(localStorage.getItem('zitlas_location') || 'null');
      if (v && typeof v === 'object' && (v.city || v.state || v.latitude)) return v;
    } catch (_) {}
    /* FALLBACK — regional personalization must NOT depend exclusively on GPS.
       When the user denied/skipped location but typed a City/State on the
       Personal Info page (personal-info.js -> personalInfo.{city,state}), use
       that. The backend region boost (location_food_engine.resolve_state) reads
       city/state exactly the same way whether they came from GPS or manual
       entry, so this is a pure input-source widening — no backend change. */
    try {
      var pi = JSON.parse(localStorage.getItem('zitlas_personal_info') || 'null');
      if (pi && typeof pi === 'object' && (pi.city || pi.state)) {
        return { city: pi.city || '', state: pi.state || '', source: 'manual' };
      }
    } catch (_) {}
    return {};
  }

  function _supplementsUsed(a) {
    var sel = Array.isArray(a.supplements_used) ? a.supplements_used : [];
    if (!sel.length) return { uses: '', types: [] };
    if (sel.indexOf('none') !== -1) return { uses: 'no', types: [] };
    return { uses: 'yes', types: sel };
  }

  function _prefList(key) {
    try {
      var v = JSON.parse(localStorage.getItem(key) || '[]');
      return Array.isArray(v) ? v.slice(0, 30) : [];
    } catch (_) { return []; }
  }

  /* ══════════════════════════════════════════
     S5: FITNESS SNAPSHOT  (redesigned)
  ══════════════════════════════════════════ */
  function renderSnapshot(calc) {
    var grid        = document.getElementById('snapshotGrid');
    var summaryEl   = document.getElementById('snapshotSummary');
    var coachEl     = document.getElementById('snapshotCoachNote');
    if (!grid) return;

    if (!calc) {
      grid.innerHTML = '<p style="color:var(--text-2);padding:20px;text-align:center">Could not load data. Check your connection and retry.</p>';
      return;
    }

    /* ── Derived values ── */
    var isMuscle         = state.selectedGoal === 'muscle_gain';
    var isGeneral        = state.selectedGoal === 'general_fitness';
    var isTransformation = state.selectedGoal === 'transformation';
    var bmi       = parseFloat(calc.bmi);
    var calories  = calc.weight_loss_calories_kcal;
    var protein   = calc.protein_target_g;
    var water     = calc.water_target_liters;
    var stepsRaw  = calc.daily_steps_goal || 0;
    var steps     = stepsRaw.toLocaleString();
    var weightDelta = calc.weight_to_lose_kg;
    var toLose    = weightDelta;
    var weeks     = calc.estimated_weeks_to_goal;
    var deficit   = calc.calorie_deficit_kcal;
    var tdee      = Math.round(calc.tdee_kcal);
    var bmr       = Math.round(calc.bmr_kcal);
    var kgPerWeek = weeks > 0 ? (weightDelta / weeks).toFixed(1) : '—';

    // General fitness: read answers for display
    var gfGoals   = Array.isArray(state.answers.health_goals) ? state.answers.health_goals : [];
    var gfLevel   = state.answers.fitness_level || 'beginner';

    var goalDate  = new Date();
    goalDate.setDate(goalDate.getDate() + weeks * 7);
    var MONTHS    = ['January','February','March','April','May','June','July',
                     'August','September','October','November','December'];
    var goalStr   = MONTHS[goalDate.getMonth()] + ' ' + goalDate.getFullYear();

    /* ── BMI classification ── */
    function bmiInfo(b) {
      if (b < 18.5) return { label: 'Underweight',    accent: 'yellow', badge: '⚠️ Needs Attention' };
      if (b < 25)   return { label: 'Healthy Weight', accent: 'green',  badge: '✓ Healthy'          };
      if (b < 30)   return { label: 'Overweight',     accent: 'yellow', badge: '⚠️ Needs Attention' };
      if (b < 35)   return { label: 'Obese Class I',  accent: 'red',    badge: '🔴 High Priority'   };
      return        { label: 'Obese Class II+',        accent: 'red',    badge: '🔴 High Priority'   };
    }
    var bStat = bmiInfo(bmi);

    /* ── SUMMARY CARD ── */
    if (summaryEl) {
      if (isTransformation) {
        summaryEl.innerHTML =
          '<div class="snap-summary-card">' +
            '<div class="snap-summary-title">' +
              '<span class="snap-summary-icon">🔥</span>' +
              '<div>' +
                '<h3 class="snap-summary-heading">Your Transformation Targets</h3>' +
                '<p class="snap-summary-sub">Daily targets to reveal your lean physique and six pack</p>' +
              '</div>' +
            '</div>' +
            '<div class="snap-summary-grid">' +
              '<div class="snap-sum-item"><span class="snap-sum-emoji">🔥</span><div><b class="snap-sum-val">' + calories.toLocaleString() + ' kcal</b><span class="snap-sum-lbl">Recomp Calories</span></div></div>' +
              '<div class="snap-sum-item"><span class="snap-sum-emoji">🥩</span><div><b class="snap-sum-val">' + protein + 'g</b><span class="snap-sum-lbl">Protein (2.2g/kg)</span></div></div>' +
              '<div class="snap-sum-item"><span class="snap-sum-emoji">💧</span><div><b class="snap-sum-val">' + water + 'L</b><span class="snap-sum-lbl">Water</span></div></div>' +
              '<div class="snap-sum-item"><span class="snap-sum-emoji">👟</span><div><b class="snap-sum-val">' + steps + '</b><span class="snap-sum-lbl">Steps</span></div></div>' +
              '<div class="snap-sum-item snap-sum-item--hl"><span class="snap-sum-emoji">⬡</span><div><b class="snap-sum-val">Six Pack + Lean</b><span class="snap-sum-lbl">Transformation Goal</span></div></div>' +
              '<div class="snap-sum-item snap-sum-item--hl"><span class="snap-sum-emoji">🗓️</span><div><b class="snap-sum-val">12–16 Weeks</b><span class="snap-sum-lbl">Visible Results</span></div></div>' +
            '</div>' +
          '</div>';
      } else if (isGeneral) {
        var gfGoalLabels = {
          energy: 'More Energy', health: 'Better Health', fitness: 'Improve Fitness',
          habits: 'Healthy Habits', mobility: 'Better Mobility', endurance: 'Better Endurance',
          strength: 'Better Strength', posture: 'Improve Posture',
          reduce_stress: 'Reduce Stress', sleep: 'Better Sleep',
        };
        var gfGoalStr = gfGoals.length > 0
          ? gfGoals.map(function(g) { return gfGoalLabels[g] || g; }).join(' · ')
          : 'General Fitness';
        summaryEl.innerHTML =
          '<div class="snap-summary-card">' +
            '<div class="snap-summary-title">' +
              '<span class="snap-summary-icon">❤️</span>' +
              '<div>' +
                '<h3 class="snap-summary-heading">Your Fitness Targets</h3>' +
                '<p class="snap-summary-sub">Your daily targets to feel healthier and more energetic</p>' +
              '</div>' +
            '</div>' +
            '<div class="snap-summary-grid">' +
              '<div class="snap-sum-item"><span class="snap-sum-emoji">⚡</span><div><b class="snap-sum-val">' + calories.toLocaleString() + ' kcal</b><span class="snap-sum-lbl">Maintenance Calories</span></div></div>' +
              '<div class="snap-sum-item"><span class="snap-sum-emoji">🥩</span><div><b class="snap-sum-val">' + protein + 'g</b><span class="snap-sum-lbl">Protein</span></div></div>' +
              '<div class="snap-sum-item"><span class="snap-sum-emoji">💧</span><div><b class="snap-sum-val">' + water + 'L</b><span class="snap-sum-lbl">Water</span></div></div>' +
              '<div class="snap-sum-item"><span class="snap-sum-emoji">👟</span><div><b class="snap-sum-val">' + steps + '</b><span class="snap-sum-lbl">Steps</span></div></div>' +
              '<div class="snap-sum-item snap-sum-item--hl"><span class="snap-sum-emoji">🌱</span><div><b class="snap-sum-val">' + esc(gfLevel.charAt(0).toUpperCase() + gfLevel.slice(1)) + '</b><span class="snap-sum-lbl">Fitness Level</span></div></div>' +
              '<div class="snap-sum-item snap-sum-item--hl"><span class="snap-sum-emoji">🗓️</span><div><b class="snap-sum-val">8–12 Weeks</b><span class="snap-sum-lbl">Est. First Results</span></div></div>' +
            '</div>' +
          '</div>';
      } else {
        summaryEl.innerHTML =
          '<div class="snap-summary-card">' +
            '<div class="snap-summary-title">' +
              '<span class="snap-summary-icon">🎯</span>' +
              '<div>' +
                '<h3 class="snap-summary-heading">Your Daily Targets</h3>' +
                '<p class="snap-summary-sub">Hit these every day to reach your goal</p>' +
              '</div>' +
            '</div>' +
            '<div class="snap-summary-grid">' +
              '<div class="snap-sum-item"><span class="snap-sum-emoji">🔥</span><div><b class="snap-sum-val">' + calories.toLocaleString() + ' kcal</b><span class="snap-sum-lbl">Daily Calories</span></div></div>' +
              '<div class="snap-sum-item"><span class="snap-sum-emoji">🥩</span><div><b class="snap-sum-val">' + protein + 'g</b><span class="snap-sum-lbl">Protein</span></div></div>' +
              '<div class="snap-sum-item"><span class="snap-sum-emoji">💧</span><div><b class="snap-sum-val">' + water + 'L</b><span class="snap-sum-lbl">Water</span></div></div>' +
              '<div class="snap-sum-item"><span class="snap-sum-emoji">👟</span><div><b class="snap-sum-val">' + steps + '</b><span class="snap-sum-lbl">Steps</span></div></div>' +
              '<div class="snap-sum-item snap-sum-item--hl"><span class="snap-sum-emoji">' + (isMuscle ? '📈' : '📉') + '</span><div><b class="snap-sum-val">~' + kgPerWeek + ' kg/wk</b><span class="snap-sum-lbl">' + (isMuscle ? 'Est. Muscle Gain' : 'Est. Weight Loss') + '</span></div></div>' +
              '<div class="snap-sum-item snap-sum-item--hl"><span class="snap-sum-emoji">📅</span><div><b class="snap-sum-val">' + goalStr + '</b><span class="snap-sum-lbl">Est. Goal Date</span></div></div>' +
            '</div>' +
          '</div>';
      }
    }

    /* ── METRIC CARD DATA ── */
    var cards;
    if (isTransformation) {
      cards = [
        {
          id: 'bmi', icon: '⚖️', type: 'CURRENT STATUS', pill: 'snap-pill--status',
          accent: bStat.accent, name: 'BMI',
          value: String(bmi), sub: bStat.label,
          badge: bStat.badge, badgeCls: 'snap-badge--' + bStat.accent,
          why: 'Body composition baseline. Abs become visible at ~10–14% body fat (men) and ~16–20% (women).',
          expandTitle: 'What does my BMI mean for transformation?',
          expand: 'Your BMI of ' + bmi + ' (' + bStat.label + ') is your starting point. Transformation is about body composition — reducing fat % while maintaining or building muscle. BMI is just one signal; waist measurement and progress photos are more relevant for transformation.',
        },
        {
          id: 'calories', icon: '🔥', type: 'DAILY TARGET', pill: 'snap-pill--target',
          accent: 'orange', name: 'Recomposition Calories',
          value: calories.toLocaleString() + ' kcal', sub: 'per day (mild deficit)',
          badge: '🎯 Daily Target', badgeCls: 'snap-badge--goal',
          why: 'A mild 250–350 kcal deficit burns fat while preserving the muscle that creates the lean physique.',
          expandTitle: 'Why a mild deficit for transformation?',
          expand: 'Your TDEE is <strong>' + tdee.toLocaleString() + ' kcal/day</strong>. Eating <strong>' + calories.toLocaleString() + ' kcal</strong> creates a mild deficit — aggressive cutting destroys muscle and slows metabolism. This sweet spot lets you lose fat AND build visible muscle simultaneously.',
        },
        {
          id: 'protein', icon: '🥩', type: 'DAILY TARGET', pill: 'snap-pill--target',
          accent: 'orange', name: 'Protein Target',
          value: protein + 'g', sub: 'per day (2.2g/kg)',
          badge: '🎯 Daily Target', badgeCls: 'snap-badge--goal',
          why: 'High protein (2.2g/kg) preserves muscle during the deficit and directly builds lean physique definition.',
          expandTitle: 'Why so much protein for transformation?',
          expand: 'Body recomposition = lose fat + build muscle simultaneously. This requires <strong>' + protein + 'g protein/day</strong> (2.2g/kg). Protein has the highest thermic effect (burns 25–30% of its own calories), keeps you full, and directly feeds muscle growth. Sources: eggs, chicken, paneer, dal, curd, soya.',
        },
        {
          id: 'water', icon: '💧', type: 'DAILY TARGET', pill: 'snap-pill--target',
          accent: 'blue', name: 'Water Intake',
          value: water + 'L', sub: 'per day',
          badge: '🎯 Daily Target', badgeCls: 'snap-badge--goal',
          why: 'Hydration flushes subcutaneous water retention — directly affects how visible your abs look.',
          expandTitle: 'Why does water matter for transformation?',
          expand: 'Paradoxically, drinking more water reduces water retention and makes muscles appear more defined. Dehydration causes the body to hold water under the skin (bloating) — hiding ab definition. Drink <strong>' + water + 'L/day</strong> consistently.',
        },
        {
          id: 'steps', icon: '👟', type: 'DAILY TARGET', pill: 'snap-pill--target',
          accent: 'orange', name: 'Daily Steps (LISS)',
          value: steps, sub: 'steps per day',
          badge: '🎯 Daily Target', badgeCls: 'snap-badge--goal',
          why: 'Low-intensity movement burns fat without burning muscle — the transformation-safe cardio.',
          expandTitle: 'Why steps for body transformation?',
          expand: steps + ' steps burns 200–300 kcal/day through LISS (Low Intensity Steady State) — the safest form of calorie burn during recomposition. Unlike HIIT, walking does not elevate cortisol or interfere with muscle recovery. It accelerates fat loss without sacrificing gains.',
        },
        {
          id: 'timeline', icon: '📅', type: 'YOUR GOAL', pill: 'snap-pill--goal',
          accent: 'purple', name: 'Transformation Timeline',
          value: '12–16 Weeks', sub: 'for visible results',
          badge: '🏆 Target', badgeCls: 'snap-badge--purple',
          why: 'Standard timeline for visible body transformation with consistent training and nutrition.',
          expandTitle: 'When will I see visible transformation?',
          expand: 'Week 1–4: Metabolic and neural adaptation. Strength increases, minor composition shift. Week 4–8: Visible fat reduction starts, muscle definition improves. Week 8–12: Abs begin to show, V-taper develops. Week 12–16: Full visible transformation — lean physique, defined core. Consistency is everything.',
        },
        {
          id: 'tdee', icon: '⚡', type: 'REFERENCE', pill: 'snap-pill--ref',
          accent: 'info', name: 'TDEE',
          value: tdee.toLocaleString() + ' kcal', sub: 'maintenance calories',
          badge: 'ℹ️ Reference', badgeCls: 'snap-badge--info',
          why: 'Your maintenance level — eat slightly below this to trigger fat loss while building muscle.',
          expandTitle: 'What is TDEE for transformation?',
          expand: '<strong>Total Daily Energy Expenditure</strong> — the calories your body burns daily. Your transformation target of ' + calories.toLocaleString() + ' kcal is 250–350 kcal below this, creating a mild fat-burning deficit while keeping protein high enough to build or preserve muscle.',
        },
        {
          id: 'bmr', icon: '🧬', type: 'REFERENCE', pill: 'snap-pill--ref',
          accent: 'info', name: 'BMR',
          value: bmr.toLocaleString() + ' kcal', sub: 'at complete rest',
          badge: 'ℹ️ Reference', badgeCls: 'snap-badge--info',
          why: 'Never eat below your BMR — it destroys muscle, which is the opposite of transformation.',
          expandTitle: 'What is BMR and why does it matter for transformation?',
          expand: '<strong>Basal Metabolic Rate</strong> — the minimum calories your body needs to function. Your target of ' + calories.toLocaleString() + ' kcal is well above your BMR (' + bmr.toLocaleString() + ' kcal), ensuring you burn fat from stored fat — not from muscle tissue.',
        },
      ];
    } else if (isGeneral) {
      var gfLevelCap = gfLevel.charAt(0).toUpperCase() + gfLevel.slice(1);
      var gfGoalLabels = {
        energy: 'More Energy', health: 'Better Health', fitness: 'Improve Fitness',
        habits: 'Healthy Habits', mobility: 'Better Mobility', endurance: 'Better Endurance',
        strength: 'Better Strength', posture: 'Improve Posture',
        reduce_stress: 'Reduce Stress', sleep: 'Better Sleep',
      };
      var gfGoalDisplay = gfGoals.length > 0
        ? gfGoals.map(function(g) { return gfGoalLabels[g] || g; }).slice(0, 3).join(', ')
        : 'General Fitness';
      cards = [
        {
          id: 'bmi', icon: '⚖️', type: 'CURRENT STATUS', pill: 'snap-pill--status',
          accent: bStat.accent, name: 'BMI',
          value: String(bmi), sub: bStat.label,
          badge: bStat.badge, badgeCls: 'snap-badge--' + bStat.accent,
          why: 'A reference measure of your body composition based on height and weight.',
          expandTitle: 'What does my BMI mean for fitness?',
          expand: 'Your BMI of ' + bmi + ' puts you in the <strong>' + bStat.label + '</strong> category. For general fitness, BMI is just one indicator — regular exercise, strength, energy, and sleep quality are equally important signals of health.',
        },
        {
          id: 'calories', icon: '⚡', type: 'DAILY TARGET', pill: 'snap-pill--target',
          accent: 'orange', name: 'Maintenance Calories',
          value: calories.toLocaleString() + ' kcal', sub: 'per day',
          badge: '🎯 Daily Target', badgeCls: 'snap-badge--goal',
          why: 'The calories your body needs to maintain current weight while fuelling exercise.',
          expandTitle: 'Why maintenance calories?',
          expand: 'For general fitness, the goal is <strong>balanced nutrition</strong> — not a deficit or surplus. Your body burns <strong>' + tdee.toLocaleString() + ' kcal/day</strong>. Eating at this level fuels your workouts, supports recovery, and maintains a healthy weight.',
        },
        {
          id: 'protein', icon: '🥩', type: 'DAILY TARGET', pill: 'snap-pill--target',
          accent: 'orange', name: 'Protein Target',
          value: protein + 'g', sub: 'per day',
          badge: '🎯 Daily Target', badgeCls: 'snap-badge--goal',
          why: 'Supports muscle maintenance, recovery after workouts, and sustained energy.',
          expandTitle: 'Why protein for general fitness?',
          expand: 'Protein repairs muscle fibres after every workout and keeps you feeling full and energized throughout the day. <strong>' + protein + 'g/day</strong> (1.6g/kg) is the optimal amount for active people focused on general fitness. Sources: eggs, dal, paneer, chicken, curd, soya.',
        },
        {
          id: 'water', icon: '💧', type: 'DAILY TARGET', pill: 'snap-pill--target',
          accent: 'blue', name: 'Water Intake',
          value: water + 'L', sub: 'per day',
          badge: '🎯 Daily Target', badgeCls: 'snap-badge--goal',
          why: 'Hydration supports energy, workout performance, and recovery.',
          expandTitle: 'Why does water matter for fitness?',
          expand: 'Even mild dehydration reduces exercise performance by 10–20% and causes fatigue. Drink <strong>' + water + 'L/day</strong> — start with a glass in the morning, drink before every workout, and sip throughout the day.',
        },
        {
          id: 'steps', icon: '👟', type: 'DAILY TARGET', pill: 'snap-pill--target',
          accent: 'orange', name: 'Daily Steps',
          value: steps, sub: 'steps per day',
          badge: '🎯 Daily Target', badgeCls: 'snap-badge--goal',
          why: 'Daily movement outside the gym — the foundation of an active, healthy lifestyle.',
          expandTitle: 'Why ' + steps + ' steps?',
          expand: steps + ' steps/day builds cardiovascular fitness, improves mood, and keeps metabolism active. Walking is the single most underrated fitness tool. Take stairs, walk during phone calls, park further away — it all counts.',
        },
        {
          id: 'fitness_level', icon: '🌱', type: 'YOUR PROFILE', pill: 'snap-pill--goal',
          accent: 'purple', name: 'Fitness Level',
          value: gfLevelCap, sub: 'starting point',
          badge: '🏆 Your Level', badgeCls: 'snap-badge--purple',
          why: 'Your starting fitness level shapes the intensity and type of training in your plan.',
          expandTitle: 'How does fitness level affect my plan?',
          expand: 'As a <strong>' + gfLevelCap + '</strong>, your plan is tailored to your starting point. Beginners focus on building the movement habit and base fitness. Intermediates add variety and challenge. Advanced athletes work on functional performance. Your level is reassessed every 8–12 weeks.',
        },
        {
          id: 'goals', icon: '❤️', type: 'YOUR PROFILE', pill: 'snap-pill--goal',
          accent: 'purple', name: 'Health Goals',
          value: gfGoalDisplay, sub: 'your focus areas',
          badge: '🏆 Your Goals', badgeCls: 'snap-badge--purple',
          why: 'Your chosen goals shape your workout and nutrition recommendations.',
          expandTitle: 'How are your goals used?',
          expand: 'Your goals — <strong>' + esc(gfGoalDisplay) + '</strong> — are used to select the right exercises, meal timing, and recovery strategies. Every session in your plan is designed to progress at least one of these areas.',
        },
        {
          id: 'timeline', icon: '📅', type: 'REFERENCE', pill: 'snap-pill--ref',
          accent: 'info', name: 'First Results',
          value: '8–12 Weeks', sub: 'for noticeable change',
          badge: 'ℹ️ Reference', badgeCls: 'snap-badge--info',
          why: 'Typical timeframe to notice meaningful fitness and energy improvements.',
          expandTitle: 'When will I see results?',
          expand: 'General fitness improvements are cumulative. Expect better energy and mood in <strong>2–3 weeks</strong>. Noticeable strength and endurance gains in <strong>6–8 weeks</strong>. Clear physical changes in <strong>10–12 weeks</strong> of consistent training. Stay the course.',
        },
        {
          id: 'tdee', icon: '⚡', type: 'REFERENCE', pill: 'snap-pill--ref',
          accent: 'info', name: 'TDEE',
          value: tdee.toLocaleString() + ' kcal', sub: 'daily energy burn',
          badge: 'ℹ️ Reference', badgeCls: 'snap-badge--info',
          why: 'Total calories your body burns per day including activity.',
          expandTitle: 'What is TDEE?',
          expand: '<strong>Total Daily Energy Expenditure</strong> — the calories your body burns daily through metabolism, digestion, and activity. Your maintenance target matches this exactly, fuelling every workout without excess fat gain or energy deficit.',
        },
        {
          id: 'bmr', icon: '🧬', type: 'REFERENCE', pill: 'snap-pill--ref',
          accent: 'info', name: 'BMR',
          value: bmr.toLocaleString() + ' kcal', sub: 'at complete rest',
          badge: 'ℹ️ Reference', badgeCls: 'snap-badge--info',
          why: 'Calories your body needs just to stay alive.',
          expandTitle: 'What is BMR?',
          expand: '<strong>Basal Metabolic Rate</strong> — the energy your body needs for breathing, heartbeat, and organ function even at rest. Never eat below your BMR (' + bmr.toLocaleString() + ' kcal). Your target of ' + calories.toLocaleString() + ' kcal is well above this.',
        },
      ];
    } else {
      cards = [
      {
        id: 'bmi', icon: '⚖️', type: 'CURRENT STATUS', pill: 'snap-pill--status',
        accent: bStat.accent, name: 'BMI',
        value: String(bmi), sub: bStat.label,
        badge: bStat.badge, badgeCls: 'snap-badge--' + bStat.accent,
        why: 'Measures whether your weight is healthy for your height.',
        expandTitle: 'What is BMI?',
        expand: 'Body Mass Index (BMI) is calculated from your height and weight. A BMI of ' + bmi + ' puts you in the <strong>' + bStat.label + '</strong> category.' +
          (bmi >= 30 ? ' Even a 5% weight reduction (≈' + (calc.weight_kg * 0.05).toFixed(1) + ' kg) significantly reduces health risks.' :
           bmi >= 25 ? ' Losing 5–10% of body weight moves you into the healthy range.' :
           ' Great — focus on maintaining this through balanced nutrition and activity.'),
      },
      {
        id: 'calories', icon: '🔥', type: 'DAILY TARGET', pill: 'snap-pill--target',
        accent: 'orange', name: 'Calorie Target',
        value: calories.toLocaleString() + ' kcal', sub: 'per day',
        badge: '🎯 Daily Goal', badgeCls: 'snap-badge--goal',
        why: isMuscle ? 'The daily calories needed to build lean muscle without excessive fat gain.' : 'The daily calories needed to lose weight steadily without starving.',
        expandTitle: 'Why this exact number?',
        expand: isMuscle
          ? 'Your body burns <strong>' + tdee.toLocaleString() + ' kcal/day</strong>. Eating ' + calories.toLocaleString() + ' kcal creates a <strong>+' + deficit + ' kcal surplus</strong> — the lean-bulk sweet spot for muscle growth with minimal fat gain.'
          : 'Your body burns <strong>' + tdee.toLocaleString() + ' kcal/day</strong> to maintain current weight. Eating ' + calories.toLocaleString() + ' kcal creates a <strong>' + deficit + ' kcal deficit</strong> — enough for steady fat loss while keeping your energy levels up.',
      },
      {
        id: 'protein', icon: '🥩', type: 'DAILY TARGET', pill: 'snap-pill--target',
        accent: 'orange', name: 'Protein Target',
        value: protein + 'g', sub: 'per day',
        badge: '🎯 Daily Goal', badgeCls: 'snap-badge--goal',
        why: isMuscle ? 'To build and repair muscle tissue after resistance training.' : 'To preserve muscle while you lose fat.',
        expandTitle: 'Why is protein so important?',
        expand: isMuscle
          ? 'Muscle protein synthesis requires a constant supply of amino acids. Eating <strong>' + protein + 'g protein/day</strong> gives your muscles the building blocks to grow after each session. Sources: eggs, dal, paneer, chicken, curd, soya.'
          : 'When you eat in a calorie deficit, your body can break down muscle for energy. Eating <strong>' + protein + 'g protein/day</strong> signals your body to burn fat instead. It also keeps you fuller for longer. Sources: eggs, dal, paneer, chicken, curd, soya.',
      },
      {
        id: 'water', icon: '💧', type: 'DAILY TARGET', pill: 'snap-pill--target',
        accent: 'blue', name: 'Water Intake',
        value: water + 'L', sub: 'per day',
        badge: '🎯 Daily Goal', badgeCls: 'snap-badge--goal',
        why: 'Supports metabolism, recovery, and hydration throughout the day.',
        expandTitle: isMuscle ? 'Why does water matter for muscle gain?' : 'Why does water matter for weight loss?',
        expand: isMuscle
          ? 'Muscles are ~75% water — even 2% dehydration reduces strength output by 10–15%. Adequate hydration also improves nutrient delivery to muscles. Drink consistently through the day, especially around training.'
          : 'Drinking water boosts metabolism by up to 30% for 1–2 hours after drinking. It also reduces false hunger — many times we eat when we are actually thirsty. Drink a glass before every meal to naturally eat less.',
      },
      {
        id: 'steps', icon: '👟', type: 'DAILY TARGET', pill: 'snap-pill--target',
        accent: 'orange', name: 'Daily Steps',
        value: steps, sub: 'steps per day',
        badge: '🎯 Daily Goal', badgeCls: 'snap-badge--goal',
        why: isMuscle ? 'Supports active recovery and cardiovascular health on rest days.' : 'Low-effort fat burning — no gym needed.',
        expandTitle: 'Why ' + steps + ' steps?',
        expand: isMuscle
          ? steps + ' steps/day promotes blood flow to recovering muscles and keeps your cardiovascular base strong. Low-intensity movement on rest days reduces soreness and speeds recovery without interfering with muscle growth.'
          : 'Walking is one of the most effective weight loss tools. ' + steps + ' steps burns approximately <strong>250–350 kcal/day</strong> — equivalent to a full snack meal — with zero equipment. Take stairs, walk during calls, park further away.',
      },
      {
        id: 'deficit', icon: isMuscle ? '📈' : '📉', type: 'DAILY TARGET', pill: 'snap-pill--target',
        accent: 'orange', name: isMuscle ? 'Calorie Surplus' : 'Calorie Deficit',
        value: deficit + ' kcal', sub: isMuscle ? 'above maintenance' : 'below maintenance',
        badge: '🎯 Daily Goal', badgeCls: 'snap-badge--goal',
        why: isMuscle ? 'The extra calories above maintenance that fuel muscle growth.' : 'The gap between what you eat and what your body burns.',
        expandTitle: isMuscle ? 'What is a calorie surplus?' : 'What is a calorie deficit?',
        expand: isMuscle
          ? 'Your body burns <strong>' + tdee.toLocaleString() + ' kcal/day</strong>. You eat <strong>' + calories.toLocaleString() + ' kcal/day</strong>. That <strong>+' + deficit + ' kcal surplus</strong> gives your muscles the extra energy needed to grow. ~2,500 kcal surplus = ~0.25 kg lean muscle gained.'
          : 'Your body burns <strong>' + tdee.toLocaleString() + ' kcal/day</strong>. You eat <strong>' + calories.toLocaleString() + ' kcal/day</strong>. The difference is <strong>' + deficit + ' kcal</strong> — your body fills that gap by burning stored fat. ~3,500 kcal deficit = ~0.45 kg of fat lost.',
      },
      {
        id: 'tdee', icon: '⚡', type: 'REFERENCE', pill: 'snap-pill--ref',
        accent: 'info', name: 'TDEE',
        value: tdee.toLocaleString() + ' kcal', sub: 'maintenance calories',
        badge: 'ℹ️ Reference', badgeCls: 'snap-badge--info',
        why: 'Estimated calories to maintain your current weight.',
        expandTitle: 'What is TDEE?',
        expand: '<strong>Total Daily Energy Expenditure</strong> — the total calories your body burns each day including activity, digestion, and movement. Eating exactly ' + tdee.toLocaleString() + ' kcal/day keeps your weight stable. ' + (isMuscle ? 'Eating slightly more = muscle growth.' : 'Eating less = fat loss.'),
      },
      {
        id: 'bmr', icon: '🧬', type: 'REFERENCE', pill: 'snap-pill--ref',
        accent: 'info', name: 'BMR',
        value: bmr.toLocaleString() + ' kcal', sub: 'at complete rest',
        badge: 'ℹ️ Reference', badgeCls: 'snap-badge--info',
        why: 'Calories your body burns just to stay alive.',
        expandTitle: 'What is BMR?',
        expand: '<strong>Basal Metabolic Rate</strong> — the energy your body needs for breathing, heartbeat, and organ function even if you stayed in bed all day. Never eat below your BMR (' + bmr.toLocaleString() + ' kcal). Your target of ' + calories.toLocaleString() + ' kcal is safely above this.',
      },
      {
        id: 'goal', icon: '🏁', type: 'YOUR GOAL', pill: 'snap-pill--goal',
        accent: 'purple', name: isMuscle ? 'Weight to Gain' : 'Weight to Lose',
        value: weightDelta + ' kg', sub: 'total target',
        badge: '🏆 Target', badgeCls: 'snap-badge--purple',
        why: 'Distance between your current and goal weight.',
        expandTitle: 'How was this calculated?',
        expand: isMuscle
          ? 'The difference between your current weight and your goal weight is <strong>' + weightDelta + ' kg</strong>. At your +' + deficit + ' kcal/day surplus, you can gain approximately <strong>' + kgPerWeek + ' kg/week</strong> of lean muscle, reaching your goal around <strong>' + goalStr + '</strong>.'
          : 'The difference between your current weight and your goal weight is <strong>' + weightDelta + ' kg</strong>. At your calorie deficit of ' + deficit + ' kcal/day, you will lose approximately <strong>' + kgPerWeek + ' kg/week</strong>, reaching your goal around <strong>' + goalStr + '</strong>.',
      },
      {
        id: 'timeline', icon: '📅', type: 'YOUR GOAL', pill: 'snap-pill--goal',
        accent: 'purple', name: 'Timeline',
        value: weeks + ' weeks', sub: '≈ ' + goalStr,
        badge: '🏆 Target', badgeCls: 'snap-badge--purple',
        why: 'Estimated time to reach your goal weight.',
        expandTitle: 'How is this estimate calculated?',
        expand: isMuscle
          ? 'Formula: lean bulk rate of 0.25 kg/week × ' + weeks + ' weeks = <strong>' + weightDelta + ' kg</strong> lean muscle gained. Your +' + deficit + ' kcal/day surplus and consistent resistance training drives this rate. Results vary by training consistency and protein adherence.'
          : 'Formula: deficit (' + deficit + ' kcal/day) × 7 ÷ 7,700 kcal/kg = <strong>' + kgPerWeek + ' kg/week</strong>. To lose ' + weightDelta + ' kg at that rate = <strong>' + weeks + ' weeks</strong>. Results vary by adherence, metabolism, and lifestyle — this is a science-based estimate, not a guarantee.',
      },
      ];
    }

    grid.innerHTML = cards.map(function (c, i) {
      return '<div class="snap-card snap-card--' + c.accent + '" style="animation-delay:' + (i * 0.04) + 's">' +
        '<div class="snap-card-inner">' +
          '<div class="snap-top-row">' +
            '<span class="snap-type-pill ' + c.pill + '">' + c.type + '</span>' +
            '<button class="snap-info-btn" data-target="snap-exp-' + c.id + '" aria-label="Learn more about ' + c.name + '">ⓘ</button>' +
          '</div>' +
          '<div class="snap-icon-row">' +
            '<span class="snap-big-icon">' + c.icon + '</span>' +
            '<span class="snap-badge ' + c.badgeCls + '">' + c.badge + '</span>' +
          '</div>' +
          '<p class="snap-metric-name">' + esc(c.name) + '</p>' +
          '<div class="snap-value-block">' +
            '<span class="snap-value">' + esc(c.value) + '</span>' +
            '<span class="snap-value-sub">' + esc(c.sub) + '</span>' +
          '</div>' +
          '<p class="snap-why-text"><strong>Why?</strong> ' + esc(c.why) + '</p>' +
        '</div>' +
        '<div class="snap-expand-panel" id="snap-exp-' + c.id + '">' +
          '<h4 class="snap-expand-title">' + esc(c.expandTitle) + '</h4>' +
          '<p class="snap-expand-body">' + c.expand + '</p>' +
        '</div>' +
      '</div>';
    }).join('');

    /* ── AI Coach Note ── */
    if (coachEl) {
      var isHighPriority = bmi >= 30;
      if (isTransformation) {
        coachEl.innerHTML =
          '<div class="snap-coach-note">' +
            '<div class="snap-coach-hdr">' +
              '<span class="snap-coach-avatar">🔥</span>' +
              '<div><p class="snap-coach-name">ZITLAS Transformation Coach</p><p class="snap-coach-sub">Body recomposition specialist</p></div>' +
            '</div>' +
            '<p class="snap-coach-text">Your BMI of <strong>' + bmi + '</strong> (' + bStat.label + ') is your current starting point. ' +
              'Transformation is not about the scale — it\'s about body composition. ' +
              'We\'re going to build visible muscle definition while systematically losing fat.</p>' +
            '<p class="snap-coach-text">Hit your daily transformation targets consistently:</p>' +
            '<ul class="snap-coach-list">' +
              '<li>✓ <strong>' + calories.toLocaleString() + ' kcal/day</strong> — mild deficit for fat loss</li>' +
              '<li>✓ <strong>' + protein + 'g protein/day</strong> — muscle preservation + growth (2.2g/kg)</li>' +
              '<li>✓ <strong>' + steps + ' steps/day</strong> — LISS cardio for fat burning</li>' +
              '<li>✓ <strong>' + water + 'L water/day</strong> — reduces bloating, improves definition</li>' +
            '</ul>' +
            '<p class="snap-coach-result">Expect visible ab definition and a lean physique by <strong>week 12–16</strong>. The transformation starts today. <strong>Let\'s build the physique you\'ve always wanted.</strong></p>' +
          '</div>';
      } else if (isGeneral) {
        var gfGoalLong = gfGoals.length > 0
          ? gfGoals.map(function(g) {
              return ({ energy:'more energy', health:'better health', fitness:'improved fitness',
                        habits:'healthy habits', mobility:'better mobility', endurance:'better endurance',
                        strength:'better strength', posture:'improved posture',
                        reduce_stress:'reduced stress', sleep:'better sleep' })[g] || g;
            }).join(', ')
          : 'better health and fitness';
        coachEl.innerHTML =
          '<div class="snap-coach-note">' +
            '<div class="snap-coach-hdr">' +
              '<span class="snap-coach-avatar">🤖</span>' +
              '<div><p class="snap-coach-name">Zino · AI Coach</p><p class="snap-coach-sub">Personalised fitness analysis</p></div>' +
            '</div>' +
            '<p class="snap-coach-text">I want to become <strong>healthier, stronger, fitter and more energetic</strong> — and your plan is built exactly for that. ' +
              'Your BMI of <strong>' + bmi + '</strong> (' + bStat.label + ') is your starting point, not your identity. ' +
              'With consistency, you\'ll feel a real difference within 8–12 weeks.</p>' +
            '<p class="snap-coach-text">Your goals — <strong>' + esc(gfGoalLong) + '</strong> — shape everything in this plan. Hit your daily targets:</p>' +
            '<ul class="snap-coach-list">' +
              '<li>✓ <strong>' + calories.toLocaleString() + ' kcal/day</strong> — fuel your body at maintenance</li>' +
              '<li>✓ <strong>' + protein + 'g protein/day</strong> — support muscle and recovery</li>' +
              '<li>✓ <strong>' + steps + ' steps/day</strong> — build your active lifestyle</li>' +
              '<li>✓ <strong>' + water + 'L water/day</strong> — stay energized and focused</li>' +
            '</ul>' +
            '<p class="snap-coach-result">Expect better energy in 2–3 weeks, noticeable fitness gains in 6–8 weeks, and real, visible change by week 12. <strong>Let\'s build a healthier you.</strong></p>' +
          '</div>';
      } else {
        coachEl.innerHTML =
          '<div class="snap-coach-note">' +
            '<div class="snap-coach-hdr">' +
              '<span class="snap-coach-avatar">🤖</span>' +
              '<div><p class="snap-coach-name">Zino · AI Nutritionist</p><p class="snap-coach-sub">Personalised analysis</p></div>' +
            '</div>' +
            '<p class="snap-coach-text">Your BMI of <strong>' + bmi + '</strong> places you in the <strong>' + bStat.label + '</strong> category. ' +
              (isMuscle ? 'The biggest opportunity right now is creating a <strong>consistent calorie surplus and resistance training stimulus</strong>.' :
               isHighPriority ? 'The biggest opportunity right now is creating a <strong>consistent daily calorie deficit</strong>.' :
               bmi >= 25 ? 'Small, consistent changes will move you into the healthy weight range.' :
               'You\'re in a healthy range — focus on building strength while maintaining your weight.') +
            '</p>' +
            '<p class="snap-coach-text">If you hit your daily targets consistently:</p>' +
            '<ul class="snap-coach-list">' +
              '<li>✓ <strong>' + calories.toLocaleString() + ' kcal/day</strong> — calorie target</li>' +
              '<li>✓ <strong>' + protein + 'g protein/day</strong> — ' + (isMuscle ? 'muscle growth' : 'muscle preservation') + '</li>' +
              '<li>✓ <strong>' + steps + ' steps/day</strong> — daily movement</li>' +
              '<li>✓ <strong>' + water + 'L water/day</strong> — metabolism support</li>' +
            '</ul>' +
            '<p class="snap-coach-result">' + (isMuscle
              ? 'You can realistically gain <strong>~' + kgPerWeek + ' kg/week</strong> of lean muscle, reaching your goal around <strong>' + goalStr + '</strong>.'
              : 'You can realistically lose <strong>~' + kgPerWeek + ' kg/week</strong>, reaching your goal around <strong>' + goalStr + '</strong>.') + '</p>' +
          '</div>';
      }
    }

    /* ── Expand/Collapse toggle ── */
    grid.querySelectorAll('.snap-info-btn').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var panel = document.getElementById(btn.getAttribute('data-target'));
        var card  = btn.closest('.snap-card');
        if (!panel) return;
        var wasOpen = panel.classList.contains('open');
        grid.querySelectorAll('.snap-expand-panel.open').forEach(function (p) { p.classList.remove('open'); });
        grid.querySelectorAll('.snap-card.snap-expanded').forEach(function (c) { c.classList.remove('snap-expanded'); });
        if (!wasOpen) {
          panel.classList.add('open');
          if (card) card.classList.add('snap-expanded');
        }
      });
    });
  }

  /* ══════════════════════════════════════════
     S6: SWOT
  ══════════════════════════════════════════ */
  function renderSwot(result) {
    var swot = result && result.swot;
    if (!swot) return;

    var archEl = document.getElementById('swotArchetypeLabel');
    if (archEl) archEl.textContent = 'Archetype: ' + (swot.user_archetype || 'Unknown');

    var grid = document.getElementById('swotGrid');
    if (grid && swot.swot) {
      var s = swot.swot;
      var items = [
        { key: 'S', icon: '💪', title: 'Strengths',     color: 'swot-S', points: s.strengths     || [] },
        { key: 'W', icon: '⚠️', title: 'Weaknesses',    color: 'swot-W', points: s.weaknesses    || [] },
        { key: 'O', icon: '🚀', title: 'Opportunities', color: 'swot-O', points: s.opportunities || [] },
        { key: 'T', icon: '🔴', title: 'Threats',       color: 'swot-T', points: s.threats       || [] },
      ];
      grid.innerHTML = items.map(function (item) {
        return '<div class="swot-card ' + item.color + '">' +
          '<div class="swot-card-header">' +
          '<span class="swot-card-icon">' + item.icon + '</span>' +
          '<span class="swot-card-title">' + item.title + '</span>' +
          '</div>' +
          '<ul>' + item.points.slice(0, 3).map(function (p) {
            var title  = esc(typeof p === 'object' ? (p.title  || '') : String(p));
            var detail = (typeof p === 'object' && p.detail) ? '<span class="swot-item-detail">' + esc(p.detail) + '</span>' : '';
            return '<li><span class="swot-item-title">✓ ' + title + '</span>' + (detail ? '<br>' + detail : '') + '</li>';
          }).join('') + '</ul>' +
          '</div>';
      }).join('');
    }

    var scoresGrid = document.getElementById('scoresGrid');
    if (scoresGrid && swot.scores) {
      var scores = swot.scores;
      var scoreKeys = [
        { key: 'nutrition',   label: 'Nutrition' },
        { key: 'activity',    label: 'Activity' },
        { key: 'sleep',       label: 'Sleep' },
        { key: 'habits',      label: 'Habits' },
        { key: 'mindset',     label: 'Mindset' },
        { key: 'consistency', label: 'Consistency' },
      ];
      scoresGrid.innerHTML = scoreKeys.map(function (sk) {
        var val = scores[sk.key] || 0;
        return '<div class="score-row">' +
          '<span class="score-name">' + sk.label + '</span>' +
          '<div class="score-track"><div class="score-bar" style="width:' + val + '%"></div></div>' +
          '<span class="score-num">' + val + '</span>' +
          '</div>';
      }).join('');
    }

    var summaryCard = document.getElementById('swotSummaryCard');
    if (summaryCard && swot.summary) {
      summaryCard.innerHTML = esc(swot.summary) +
        (swot.priority_action ? '<p class="swot-priority">→ ' + esc(swot.priority_action) + '</p>' : '');
    }
  }

  /* ══════════════════════════════════════════
     S7: DIET PLAN
  ══════════════════════════════════════════ */
  function renderDiet(result) {
    var plan = result && result.diet_plan;
    var calc = result && result.calculations;
    if (!plan) { showFallback('dietDays', 'Diet plan could not be loaded.'); return; }

    var nameEl = document.getElementById('dietPlanName');
    if (nameEl) nameEl.textContent = plan.plan_name || 'Personalised 7-Day Diet Plan';

    var targetsEl = document.getElementById('dietTargets');
    if (targetsEl && calc) {
      var dietIsMuscle         = state.selectedGoal === 'muscle_gain';
      var dietIsTransformation = state.selectedGoal === 'transformation';
      var deficitLabel = dietIsMuscle ? 'Surplus' : (dietIsTransformation ? 'Mild Deficit' : 'Deficit');
      targetsEl.innerHTML = [
        { val: (plan.daily_calories_target || calc.weight_loss_calories_kcal) + ' kcal', lbl: 'Calories' },
        { val: (plan.daily_protein_target_g || calc.protein_target_g) + 'g', lbl: 'Protein' },
        { val: calc.water_target_liters + 'L', lbl: 'Water' },
        { val: calc.calorie_deficit_kcal + ' kcal', lbl: deficitLabel },
      ].map(function (t) {
        return '<div class="target-chip"><div class="target-chip-val">' + esc(String(t.val)) + '</div><div class="target-chip-lbl">' + esc(t.lbl) + '</div></div>';
      }).join('');
    }

    var summaryEl = document.getElementById('dietSummary');
    if (summaryEl && plan.summary) summaryEl.textContent = plan.summary;

    var daysEl = document.getElementById('dietDays');
    if (daysEl && plan.days) {
      daysEl.innerHTML = plan.days.map(function (day, i) {
        var mealsHtml = (day.meals || []).map(function (meal) {
          return '<div class="meal-card">' +
            '<div class="meal-header"><span class="meal-name">' + esc(meal.meal_name || '') + '</span>' +
            '<span class="meal-time">' + esc(meal.time || '') + '</span></div>' +
            '<div class="meal-macros">' + (meal.calories || 0) + ' kcal · ' + (meal.protein_g || 0) + 'g protein</div>' +
            '<div class="meal-foods">' + esc((meal.foods || []).join(', ')) + '</div>' +
            (meal.tip ? '<div class="meal-tip">💡 ' + esc(meal.tip) + '</div>' : '') +
            '</div>';
        }).join('');
        return '<div class="acc-item" id="dietDay' + i + '">' +
          '<button class="acc-trigger" data-idx="' + i + '" data-type="diet">' +
          '<div class="acc-trigger-left">' +
          '<span class="acc-day-badge">' + esc(day.day || ('Day ' + (i+1))) + '</span>' +
          '<span class="acc-day-focus">' + esc(day.theme || '') + '</span>' +
          '</div>' +
          '<span class="acc-arrow">▼</span>' +
          '</button>' +
          '<div class="acc-body">' + mealsHtml +
          '<div class="day-totals">' +
          '<div class="day-total-item"><span class="day-total-val">' + (day.total_calories || 0) + '</span> kcal</div>' +
          '<div class="day-total-item"><span class="day-total-val">' + (day.total_protein_g || 0) + '</span>g protein</div>' +
          '</div></div></div>';
      }).join('');
    }

    var rulesEl = document.getElementById('dietRules');
    if (rulesEl && plan.key_rules && plan.key_rules.length) {
      rulesEl.innerHTML = '<div class="plan-rules-title">Key Rules</div>' +
        plan.key_rules.map(function (r) {
          return '<div class="plan-rule">' + esc(r) + '</div>';
        }).join('');
    }
  }

  /* ══════════════════════════════════════════
     S8: WORKOUT PLAN
  ══════════════════════════════════════════ */
  function renderWorkout(result) {
    var plan = result && result.workout_plan;
    if (!plan) { showFallback('workoutDays', 'Workout plan could not be loaded.'); return; }

    var nameEl = document.getElementById('workoutPlanName');
    if (nameEl) nameEl.textContent = (plan.plan_name || 'Personalised 7-Day Workout Plan') + (plan.weekly_frequency ? '  ·  ' + plan.weekly_frequency : '');

    var workoutIsMuscle         = state.selectedGoal === 'muscle_gain';
    var workoutIsTransformation = state.selectedGoal === 'transformation';
    var targetsEl = document.getElementById('workoutTargets');
    if (targetsEl) {
      var volumeChip = (workoutIsMuscle || workoutIsTransformation)
        ? { val: (plan.weekly_training_volume_sets || '—') + ' sets', lbl: 'Weekly Volume' }
        : { val: (plan.weekly_calorie_burn_est || '—') + ' kcal', lbl: 'Weekly Burn' };
      var splitChip = (workoutIsMuscle || workoutIsTransformation) && plan.training_split
        ? { val: plan.training_split, lbl: 'Split' }
        : null;
      var chips = [
        { val: plan.weekly_frequency || '5 days/week', lbl: 'Frequency' },
        volumeChip,
      ];
      if (splitChip) chips.push(splitChip);
      targetsEl.innerHTML = chips.map(function (t) {
        return '<div class="target-chip"><div class="target-chip-val">' + esc(String(t.val)) + '</div><div class="target-chip-lbl">' + esc(t.lbl) + '</div></div>';
      }).join('');
    }

    var summaryEl = document.getElementById('workoutSummary');
    if (summaryEl && plan.summary) summaryEl.textContent = plan.summary;

    var daysEl = document.getElementById('workoutDays');
    if (daysEl && plan.weekly_plan) {
      daysEl.innerHTML = plan.weekly_plan.map(function (day, i) {
        var typeClass = (day.type || '').toLowerCase().includes('rest') ? 'rest'
          : (day.type || '').toLowerCase().includes('recovery') ? 'recovery' : 'workout';

        var exercisesHtml = (day.exercises || []).map(function (ex) {
          return '<div class="exercise-card">' +
            '<div class="exercise-name">' + esc(ex.name || '') + '</div>' +
            '<div class="exercise-meta">' +
            (ex.sets ? ex.sets + ' sets · ' : '') +
            esc(ex.reps_or_duration || '') +
            (ex.rest_seconds ? ' · ' + ex.rest_seconds + 's rest' : '') +
            '</div>' +
            (ex.tip ? '<div class="exercise-tip">💡 ' + esc(ex.tip) + '</div>' : '') +
            (ex.progression ? '<div class="exercise-tip">📈 <strong>Progress:</strong> ' + esc(ex.progression) + '</div>' : '') +
            '</div>';
        }).join('');

        var dayVolumeBadge = (workoutIsMuscle || workoutIsTransformation)
          ? (day.sets_volume_est ? '<span class="workout-type-badge workout">' + day.sets_volume_est + ' sets</span>' : '')
          : (day.calories_burned_est ? '<span class="workout-type-badge workout">~' + day.calories_burned_est + ' kcal</span>' : '');

        return '<div class="acc-item" id="workoutDay' + i + '">' +
          '<button class="acc-trigger" data-idx="' + i + '" data-type="workout">' +
          '<div class="acc-trigger-left">' +
          '<span class="acc-day-badge">' + esc(day.day || ('Day ' + (i+1))) + '</span>' +
          '<span class="acc-day-focus">' + esc(day.focus || day.type || '') + '</span>' +
          '</div>' +
          '<span class="acc-arrow">▼</span>' +
          '</button>' +
          '<div class="acc-body">' +
          '<div class="workout-day-header">' +
          '<span class="workout-type-badge ' + typeClass + '">' + esc(day.type || '') + '</span>' +
          (day.duration_minutes ? '<span class="workout-type-badge workout">' + day.duration_minutes + ' min</span>' : '') +
          dayVolumeBadge +
          '</div>' +
          exercisesHtml +
          (day.daily_tip ? '<div class="day-tip-card">💡 ' + esc(day.daily_tip) + '</div>' : '') +
          '</div></div>';
      }).join('');
    }
  }

  /* ══════════════════════════════════════════
     ACCORDION DELEGATION
  ══════════════════════════════════════════ */
  function initAccordions() {
    document.addEventListener('click', function (e) {
      var trigger = e.target.closest('.acc-trigger');
      if (!trigger) return;
      var item = trigger.closest('.acc-item');
      if (!item) return;
      var isOpen = item.classList.contains('open');
      // Close all siblings
      var parent = item.parentNode;
      if (parent) {
        parent.querySelectorAll('.acc-item.open').forEach(function (el) { el.classList.remove('open'); });
      }
      if (!isOpen) item.classList.add('open');
    });
  }

  /* ══════════════════════════════════════════
     LOCAL STORAGE
  ══════════════════════════════════════════ */
  function saveToLocalStorage(data) {
    try {
      if (data.calculations)  localStorage.setItem('zitlas_calculations',  JSON.stringify(data.calculations));
      if (data.swot)          localStorage.setItem('zitlas_swot',          JSON.stringify(data.swot));
      if (data.diet_plan) {
        var _aiPlanStorage = {
          originalDietPlan:    data.diet_plan,
          currentDietPlan:     data.diet_plan,
          expertModifications: {},
          isExpertPlan:        false,
        };
        localStorage.setItem('zitlas_diet_plan', JSON.stringify(_aiPlanStorage));
        /* Geo-Aware Food Intelligence: one-line "why these meals" explanation,
           only ever present when the user has a saved location that matched
           a known region (see services/location_food_engine.py). */
        if (data.diet_plan.location_note) {
          localStorage.setItem('zitlas_location_note', data.diet_plan.location_note);
        } else {
          localStorage.removeItem('zitlas_location_note');
        }
      }
      if (data.workout_plan) {
        /* Wrap in new schema (mirrors diet) so schema detection in weekly-plan / day.js
           always finds originalWorkoutPlan and workoutModifications is always present. */
        var _aiWorkoutStorage = {
          originalWorkoutPlan:  data.workout_plan,
          currentWorkoutPlan:   JSON.parse(JSON.stringify(data.workout_plan)),
          workoutModifications: {},
          isExpertPlan:         false,
          expertName:           null,
          reviewedAt:           null,
        };
        localStorage.setItem('zitlas_workout_plan', JSON.stringify(_aiWorkoutStorage));
      }
      if (data.sources)       localStorage.setItem('zitlas_sources',       JSON.stringify(data.sources));
      if (data.assessment)    localStorage.setItem('zitlas_assessment',    JSON.stringify(data.assessment));
      /* Deterministic (never LLM-generated) medical-condition precautions —
         computed server-side by services/medical_conditions.py. Empty for
         healthy users, so this key is simply absent for them. */
      if (data.precautions && data.precautions.length) {
        localStorage.setItem('zitlas_precautions', JSON.stringify({
          precautions: data.precautions,
          conditions:  data.medical_conditions_detected || [],
          directives:  data.medical_directives || null,
        }));
      } else {
        localStorage.removeItem('zitlas_precautions');
      }
      localStorage.setItem('zitlas_plan_generated_at', new Date().toISOString());
      /* Stamp a new planId so any prior expert review is automatically invalidated */
      var _newPlanId = 'plan_' + Date.now();
      localStorage.setItem('zitlas_plan_id', _newPlanId);
      console.log('[AI-COACH] saveToLocalStorage — new planId stamped:', _newPlanId);

      // Build goal for dashboard compatibility
      var a       = state.answers;
      var _isGF   = state.selectedGoal === 'general_fitness';
      var _isMG   = state.selectedGoal === 'muscle_gain';
      var _isTF   = state.selectedGoal === 'transformation';
      var goalType = (
        _isGF ? 'General Fitness' :
        _isMG ? 'Muscle Gain'     :
        _isTF ? 'Transformation'  :
        'Weight Loss'
      );
      // GF and Transformation have no separate target weight — use current weight
      var goalTarget = (_isGF || _isTF) ? (a.weight_kg || 75) : (a.goal_weight_kg || 65);
      var goal = {
        type:       goalType,
        currentVal: a.weight_kg || 75,
        targetVal:  goalTarget,
        unit:       'kg',
        startDate:  new Date().toISOString().slice(0, 10),
        endDate:    new Date(Date.now() + 90 * 864e5).toISOString().slice(0, 10),
      };
      localStorage.setItem('zitlas_goal',   JSON.stringify(goal));
      localStorage.setItem('zitlas_survey', JSON.stringify(state.answers));
      localStorage.removeItem('nutrition_weekly_plan');
      /* New plan ID was already stamped above — clear stale expert review for old planId */
      ['zitlas_expert_review', 'zitlas_plan_versions', 'zitlas_review_request',
       'expert_plan_reviews',
       'expert_review', 'expert_diet_override', 'reviewed_diet_plan',
       'modifiedBy', 'expertApproval', 'review_request',
       'expertDiet', 'expertOverride', 'dietOverride', 'reviewStatus',
       'expertReviewedPlan', 'approvedPlan', 'expertWorkoutOverride',
      ].forEach(function(k) { localStorage.removeItem(k); });
      console.log('[AI-COACH] New plan saved — all expert review keys cleared');
      /* Local keys alone aren't durable — assets/js/review-sync.js's live
         Firestore listener treats "no local review cache" as "resync from
         Firestore" and can silently repopulate them from the OLD review's
         still-live review_requests doc. Dismiss it there too so a fresh
         plan (or a retaken assessment, which funnels through this same
         function) never has a stale review reattach itself. Fire-and-
         forget — this function doesn't block on network and the page
         isn't navigating away. */
      if (typeof ZitlasCoachingReset !== 'undefined') ZitlasCoachingReset.clearAll({});

      /* Push everything to Firestore in one write so every other device
         logged into this account sees the identical plan — this was
         previously localStorage-only, the root cause of cross-device
         desync (goal/diet/workout/assessment/SWOT never left the device
         that generated them). */
      if (typeof ZitlasCloudSync !== 'undefined') {
        var _bulk = { goal: goal, survey: state.answers };
        if (data.calculations) _bulk.calculations = data.calculations;
        if (data.swot)         _bulk.swot = data.swot;
        if (data.assessment)   _bulk.assessment = data.assessment;
        if (data.diet_plan)    _bulk.dietPlan = JSON.parse(localStorage.getItem('zitlas_diet_plan'));
        if (data.workout_plan) _bulk.workoutPlan = JSON.parse(localStorage.getItem('zitlas_workout_plan'));
        var _precautionsRaw = localStorage.getItem('zitlas_precautions');
        _bulk.precautions = _precautionsRaw ? JSON.parse(_precautionsRaw) : null;
        _bulk.planGeneratedAt = new Date().toISOString();
        _bulk.planId = _newPlanId;
        /* IMMUTABLE MASTER SNAPSHOTS — written ONCE per generation and
           never touched by any expert/coach/accept/swap flow (those all
           write dietPlan/workoutPlan). If the working copy is ever lost
           or corrupted (e.g. an expert modification gone wrong), diet.js
           recovers the plan from here instead of showing "No Plan Yet".
           Cloud-only (not in cloud-sync's FIELD_MAP): saveBulk writes
           unknown keys straight to the users/{uid} patch without a
           localStorage mirror, so local corruption can't reach them.
           Cleared by Goal Reset via clearGoalData (goal-scoped). */
        if (data.diet_plan)    _bulk.dietPlanMaster    = { plan: data.diet_plan,    planId: _newPlanId, generatedAt: _bulk.planGeneratedAt };
        if (data.workout_plan) _bulk.workoutPlanMaster = { plan: data.workout_plan, planId: _newPlanId, generatedAt: _bulk.planGeneratedAt };
        ZitlasCloudSync.saveBulk(_bulk);
        console.log('[AI-COACH] plan synced to Firestore — visible on every device now');
      }
    } catch (_) {}
  }

  /* ══════════════════════════════════════════
     UTILITY
  ══════════════════════════════════════════ */
  function esc(str) {
    return String(str || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }

  function showFallback(elId, msg) {
    var el = document.getElementById(elId);
    if (el) el.innerHTML = '<p style="color:var(--text-3);font-size:13px;padding:20px;text-align:center">' + msg + '</p>';
  }

  /* ══════════════════════════════════════════
     INIT & WIRING
  ══════════════════════════════════════════ */
  function init() {
    initAccordions();

    // S1 → S2
    var btnStart = document.getElementById('btnStart');
    if (btnStart) btnStart.addEventListener('click', function () { showScreen('s-goal'); });

    // S2 back
    var backBtns = document.querySelectorAll('.back-btn[data-back]');
    backBtns.forEach(function (btn) {
      btn.addEventListener('click', function () { showScreen(btn.dataset.back); });
    });

    // S2: Goal card selection
    var goalCards = document.querySelectorAll('.goal-card');
    goalCards.forEach(function (card) {
      if (card.disabled) return;
      card.addEventListener('click', function () {
        goalCards.forEach(function (c) { c.classList.remove('selected'); });
        card.classList.add('selected');
        state.selectedGoal = card.dataset.goal || 'lose_weight';
      });
    });

    // S2 → S3
    var btnGoalNext = document.getElementById('btnGoalNext');
    if (btnGoalNext) {
      btnGoalNext.addEventListener('click', function () {
        state.currentQ = 0;
        state.answers  = {};
        showScreen('s-assess');
        renderQuestion(0);
      });
    }

    // S3 back (go to previous question or to s-goal)
    var assessBack = document.getElementById('assessBackBtn');
    if (assessBack) {
      assessBack.addEventListener('click', function () {
        if (state.currentQ === 0) {
          showScreen('s-goal');
        } else {
          state.currentQ--;
          renderQuestion(state.currentQ);
        }
      });
    }

    // S5 → S6
    var btnSnap = document.getElementById('btnSnapshotNext');
    if (btnSnap) {
      btnSnap.addEventListener('click', function () {
        showScreen('s-swot');
        renderSwot(state.apiResult);
      });
    }

    // S6 → S7
    var btnSwot = document.getElementById('btnSwotNext');
    if (btnSwot) {
      btnSwot.addEventListener('click', function () {
        showScreen('s-diet');
        renderDiet(state.apiResult);
      });
    }

    // S7 → S8
    var btnDiet = document.getElementById('btnDietNext');
    if (btnDiet) {
      btnDiet.addEventListener('click', function () {
        showScreen('s-workout');
        renderWorkout(state.apiResult);
      });
    }

    // S8 → S11 (Done). The ₹149 expert-review upsell no longer interrupts
    // onboarding — it's offered later as an optional card on the dashboard
    // (see dashboard.js) once the user has actually seen their AI plan.
    var btnWorkout = document.getElementById('btnWorkoutNext');
    if (btnWorkout) {
      btnWorkout.addEventListener('click', function () { showScreen('s-done'); });
    }

    // S11 → Dashboard
    var btnDone = document.getElementById('btnDone');
    if (btnDone) {
      btnDone.addEventListener('click', function () {
        window.location.href = '../dashboard.html';
      });
    }

    // Deep-link support: ?view=swot or ?view=workout
    var viewParam = new URLSearchParams(window.location.search).get('view');
    if (viewParam === 'swot') {
      try {
        var savedSwot = JSON.parse(localStorage.getItem('zitlas_swot') || 'null');
        console.log('SWOT DATA:', savedSwot);
        if (savedSwot) {
          state.apiResult = {
            swot:         savedSwot,
            calculations: JSON.parse(localStorage.getItem('zitlas_calculations') || 'null'),
            assessment:   JSON.parse(localStorage.getItem('zitlas_assessment')   || 'null'),
          };
          showScreen('s-swot');
          renderSwot(state.apiResult);
          return;
        }
      } catch (_) {}
    }
    if (viewParam === 'workout') {
      try {
        var savedWorkout = JSON.parse(localStorage.getItem('zitlas_workout_plan') || 'null');
        console.log('WORKOUT PLAN:', savedWorkout);
        if (savedWorkout) {
          state.apiResult = { workout_plan: savedWorkout };
          showScreen('s-workout');
          renderWorkout(state.apiResult);
          return;
        }
      } catch (_) {}
    }

    // Default: show welcome screen
    showScreen('s-welcome');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
