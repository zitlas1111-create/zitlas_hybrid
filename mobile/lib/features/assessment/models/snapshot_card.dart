/// Every metric card, summary card, and AI-coach note shown on the Fitness
/// Snapshot screen (S5) — transcribed verbatim from `renderSnapshot()` in
/// `frontend/pages/dashboard/ai-coach/ai-coach.js` (lines ~1360-1874), one
/// builder per goal branch (default/weight-loss+muscle-gain, general
/// fitness, transformation). All numbers come from the real
/// `AssessmentCalculations` the backend returned; only wording/thresholds
/// are literal ports.
library;

import 'assessment_calculations.dart';

String thousands(num n) {
  final isInt = n == n.roundToDouble();
  final s = isInt ? n.round().toString() : n.toString();
  final parts = s.split('.');
  final intPart = parts[0];
  final neg = intPart.startsWith('-');
  final digits = neg ? intPart.substring(1) : intPart;
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  final head = (neg ? '-' : '') + buf.toString();
  return parts.length > 1 ? '$head.${parts[1]}' : head;
}

/// `bmiInfo(b)` — the Snapshot screen's OWN BMI categorization, distinct
/// from `calculations.bmi_category` (see that field's doc comment). Used
/// only here, exactly as on the website.
class BmiInfo {
  const BmiInfo({required this.label, required this.accent, required this.badge});
  final String label;

  /// 'yellow' | 'green' | 'red' — mapped to a color in the widget layer.
  final String accent;
  final String badge;
}

BmiInfo bmiInfo(num b) {
  if (b < 18.5) return const BmiInfo(label: 'Underweight', accent: 'yellow', badge: '⚠️ Needs Attention');
  if (b < 25) return const BmiInfo(label: 'Healthy Weight', accent: 'green', badge: '✓ Healthy');
  if (b < 30) return const BmiInfo(label: 'Overweight', accent: 'yellow', badge: '⚠️ Needs Attention');
  if (b < 35) return const BmiInfo(label: 'Obese Class I', accent: 'red', badge: '🔴 High Priority');
  return const BmiInfo(label: 'Obese Class II+', accent: 'red', badge: '🔴 High Priority');
}

/// One metric card. `accent`: yellow|green|red|orange|blue|purple|info.
/// `type`: the small pill label ("CURRENT STATUS" etc). `badge`: the pill
/// under the big icon.
class SnapshotCard {
  const SnapshotCard({
    required this.id,
    required this.icon,
    required this.type,
    required this.accent,
    required this.name,
    required this.value,
    required this.sub,
    required this.badge,
    required this.why,
    required this.expandTitle,
    required this.expand,
  });

  final String id;
  final String icon;
  final String type;
  final String accent;
  final String name;
  final String value;
  final String sub;
  final String badge;
  final String why;

  /// Plain text with `<strong>` markers preserved literally (the website
  /// injects raw HTML here) — the widget layer strips/bolds them.
  final String expandTitle;
  final String expand;
}

class SnapshotSummaryItem {
  const SnapshotSummaryItem({required this.emoji, required this.value, required this.label, this.highlight = false});
  final String emoji;
  final String value;
  final String label;
  final bool highlight;
}

class SnapshotSummary {
  const SnapshotSummary({
    required this.icon,
    required this.heading,
    required this.sub,
    required this.items,
  });
  final String icon;
  final String heading;
  final String sub;
  final List<SnapshotSummaryItem> items;
}

class CoachNote {
  const CoachNote({
    required this.avatar,
    required this.name,
    required this.sub,
    required this.paragraphs,
    required this.bullets,
    required this.result,
  });
  final String avatar;
  final String name;
  final String sub;
  final List<String> paragraphs;
  final List<String> bullets;
  final String result;
}

String _goalDateLabel(num weeks, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final goalDate = n.add(Duration(days: (weeks * 7).round()));
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  return '${months[goalDate.month - 1]} ${goalDate.year}';
}

String _kgPerWeek(num weightDelta, num weeks) {
  if (weeks <= 0) return '—';
  return (weightDelta / weeks).toStringAsFixed(1);
}

// ═══════════════════════════════════════════════════════════════
// DEFAULT (weight_loss / muscle_gain)
// ═══════════════════════════════════════════════════════════════

SnapshotSummary buildDefaultSummary(AssessmentCalculations calc, {required bool isMuscle, DateTime? now}) {
  final goalStr = _goalDateLabel(calc.estimatedWeeksToGoal, now: now);
  final kgPerWeek = _kgPerWeek(calc.weightDeltaKg, calc.estimatedWeeksToGoal);
  return SnapshotSummary(
    icon: '🎯',
    heading: 'Your Daily Targets',
    sub: 'Hit these every day to reach your goal',
    items: [
      SnapshotSummaryItem(emoji: '🔥', value: '${thousands(calc.calorieTargetKcal)} kcal', label: 'Daily Calories'),
      SnapshotSummaryItem(emoji: '🥩', value: '${thousands(calc.proteinTargetG)}g', label: 'Protein'),
      SnapshotSummaryItem(emoji: '💧', value: '${thousands(calc.waterTargetLiters)}L', label: 'Water'),
      SnapshotSummaryItem(emoji: '👟', value: thousands(calc.dailyStepsGoal), label: 'Steps'),
      SnapshotSummaryItem(
        emoji: isMuscle ? '📈' : '📉',
        value: '~$kgPerWeek kg/wk',
        label: isMuscle ? 'Est. Muscle Gain' : 'Est. Weight Loss',
        highlight: true,
      ),
      SnapshotSummaryItem(emoji: '📅', value: goalStr, label: 'Est. Goal Date', highlight: true),
    ],
  );
}

List<SnapshotCard> buildDefaultCards(AssessmentCalculations calc, {required bool isMuscle, DateTime? now}) {
  final bStat = bmiInfo(calc.bmi);
  final steps = thousands(calc.dailyStepsGoal);
  final calories = thousands(calc.calorieTargetKcal);
  final protein = thousands(calc.proteinTargetG);
  final water = thousands(calc.waterTargetLiters);
  final tdee = thousands(calc.tdeeKcal.round());
  final bmr = thousands(calc.bmrKcal.round());
  final deficit = calc.calorieDeficitKcal;
  final weightDelta = calc.weightDeltaKg;
  final weeks = calc.estimatedWeeksToGoal;
  final goalStr = _goalDateLabel(weeks, now: now);
  final kgPerWeek = _kgPerWeek(weightDelta, weeks);
  final isHighPriority = calc.bmi >= 30;

  return [
    SnapshotCard(
      id: 'bmi',
      icon: '⚖️',
      type: 'CURRENT STATUS',
      accent: bStat.accent,
      name: 'BMI',
      value: '${calc.bmi}',
      sub: bStat.label,
      badge: bStat.badge,
      why: 'Measures whether your weight is healthy for your height.',
      expandTitle: 'What is BMI?',
      expand: 'Body Mass Index (BMI) is calculated from your height and weight. '
          'A BMI of ${calc.bmi} puts you in the <strong>${bStat.label}</strong> category.'
          '${isHighPriority ? ' Even a 5% weight reduction significantly reduces health risks.' : calc.bmi >= 25 ? ' Losing 5–10% of body weight moves you into the healthy range.' : ' Great — focus on maintaining this through balanced nutrition and activity.'}',
    ),
    SnapshotCard(
      id: 'calories',
      icon: '🔥',
      type: 'DAILY TARGET',
      accent: 'orange',
      name: 'Calorie Target',
      value: '$calories kcal',
      sub: 'per day',
      badge: '🎯 Daily Goal',
      why: isMuscle
          ? 'The daily calories needed to build lean muscle without excessive fat gain.'
          : 'The daily calories needed to lose weight steadily without starving.',
      expandTitle: 'Why this exact number?',
      expand: isMuscle
          ? 'Your body burns <strong>$tdee kcal/day</strong>. Eating $calories kcal creates a '
              '<strong>+$deficit kcal surplus</strong> — the lean-bulk sweet spot for muscle growth with minimal fat gain.'
          : 'Your body burns <strong>$tdee kcal/day</strong> to maintain current weight. Eating $calories kcal creates a '
              '<strong>$deficit kcal deficit</strong> — enough for steady fat loss while keeping your energy levels up.',
    ),
    SnapshotCard(
      id: 'protein',
      icon: '🥩',
      type: 'DAILY TARGET',
      accent: 'orange',
      name: 'Protein Target',
      value: '${protein}g',
      sub: 'per day',
      badge: '🎯 Daily Goal',
      why: isMuscle
          ? 'To build and repair muscle tissue after resistance training.'
          : 'To preserve muscle while you lose fat.',
      expandTitle: 'Why is protein so important?',
      expand: isMuscle
          ? 'Muscle protein synthesis requires a constant supply of amino acids. Eating '
              '<strong>${protein}g protein/day</strong> gives your muscles the building blocks to grow after each session. '
              'Sources: eggs, dal, paneer, chicken, curd, soya.'
          : 'When you eat in a calorie deficit, your body can break down muscle for energy. Eating '
              '<strong>${protein}g protein/day</strong> signals your body to burn fat instead. It also keeps you fuller for longer. '
              'Sources: eggs, dal, paneer, chicken, curd, soya.',
    ),
    SnapshotCard(
      id: 'water',
      icon: '💧',
      type: 'DAILY TARGET',
      accent: 'blue',
      name: 'Water Intake',
      value: '${water}L',
      sub: 'per day',
      badge: '🎯 Daily Goal',
      why: 'Supports metabolism, recovery, and hydration throughout the day.',
      expandTitle: isMuscle ? 'Why does water matter for muscle gain?' : 'Why does water matter for weight loss?',
      expand: isMuscle
          ? 'Muscles are ~75% water — even 2% dehydration reduces strength output by 10–15%. Adequate hydration also improves '
              'nutrient delivery to muscles. Drink consistently through the day, especially around training.'
          : 'Drinking water boosts metabolism by up to 30% for 1–2 hours after drinking. It also reduces false hunger — many '
              'times we eat when we are actually thirsty. Drink a glass before every meal to naturally eat less.',
    ),
    SnapshotCard(
      id: 'steps',
      icon: '👟',
      type: 'DAILY TARGET',
      accent: 'orange',
      name: 'Daily Steps',
      value: steps,
      sub: 'steps per day',
      badge: '🎯 Daily Goal',
      why: isMuscle
          ? 'Supports active recovery and cardiovascular health on rest days.'
          : 'Low-effort fat burning — no gym needed.',
      expandTitle: 'Why $steps steps?',
      expand: isMuscle
          ? '$steps steps/day promotes blood flow to recovering muscles and keeps your cardiovascular base strong. '
              'Low-intensity movement on rest days reduces soreness and speeds recovery without interfering with muscle growth.'
          : 'Walking is one of the most effective weight loss tools. $steps steps burns approximately '
              '<strong>250–350 kcal/day</strong> — equivalent to a full snack meal — with zero equipment. Take stairs, walk during '
              'calls, park further away.',
    ),
    SnapshotCard(
      id: 'deficit',
      icon: isMuscle ? '📈' : '📉',
      type: 'DAILY TARGET',
      accent: 'orange',
      name: isMuscle ? 'Calorie Surplus' : 'Calorie Deficit',
      value: '$deficit kcal',
      sub: isMuscle ? 'above maintenance' : 'below maintenance',
      badge: '🎯 Daily Goal',
      why: isMuscle
          ? 'The extra calories above maintenance that fuel muscle growth.'
          : 'The gap between what you eat and what your body burns.',
      expandTitle: isMuscle ? 'What is a calorie surplus?' : 'What is a calorie deficit?',
      expand: isMuscle
          ? 'Your body burns <strong>$tdee kcal/day</strong>. You eat <strong>$calories kcal/day</strong>. That '
              '<strong>+$deficit kcal surplus</strong> gives your muscles the extra energy needed to grow. ~2,500 kcal surplus = '
              '~0.25 kg lean muscle gained.'
          : 'Your body burns <strong>$tdee kcal/day</strong>. You eat <strong>$calories kcal/day</strong>. The difference is '
              '<strong>$deficit kcal</strong> — your body fills that gap by burning stored fat. ~3,500 kcal deficit = ~0.45 kg of '
              'fat lost.',
    ),
    SnapshotCard(
      id: 'tdee',
      icon: '⚡',
      type: 'REFERENCE',
      accent: 'info',
      name: 'TDEE',
      value: '$tdee kcal',
      sub: 'maintenance calories',
      badge: 'ℹ️ Reference',
      why: 'Estimated calories to maintain your current weight.',
      expandTitle: 'What is TDEE?',
      expand: '<strong>Total Daily Energy Expenditure</strong> — the total calories your body burns each day including '
          'activity, digestion, and movement. Eating exactly $tdee kcal/day keeps your weight stable. '
          '${isMuscle ? 'Eating slightly more = muscle growth.' : 'Eating less = fat loss.'}',
    ),
    SnapshotCard(
      id: 'bmr',
      icon: '🧬',
      type: 'REFERENCE',
      accent: 'info',
      name: 'BMR',
      value: '$bmr kcal',
      sub: 'at complete rest',
      badge: 'ℹ️ Reference',
      why: 'Calories your body burns just to stay alive.',
      expandTitle: 'What is BMR?',
      expand: '<strong>Basal Metabolic Rate</strong> — the energy your body needs for breathing, heartbeat, and organ '
          'function even if you stayed in bed all day. Never eat below your BMR ($bmr kcal). Your target of $calories kcal '
          'is safely above this.',
    ),
    SnapshotCard(
      id: 'goal',
      icon: '🏁',
      type: 'YOUR GOAL',
      accent: 'purple',
      name: isMuscle ? 'Weight to Gain' : 'Weight to Lose',
      value: '$weightDelta kg',
      sub: 'total target',
      badge: '🏆 Target',
      why: 'Distance between your current and goal weight.',
      expandTitle: 'How was this calculated?',
      expand: isMuscle
          ? 'The difference between your current weight and your goal weight is <strong>$weightDelta kg</strong>. At your '
              '+$deficit kcal/day surplus, you can gain approximately <strong>$kgPerWeek kg/week</strong> of lean muscle, '
              'reaching your goal around <strong>$goalStr</strong>.'
          : 'The difference between your current weight and your goal weight is <strong>$weightDelta kg</strong>. At your '
              'calorie deficit of $deficit kcal/day, you will lose approximately <strong>$kgPerWeek kg/week</strong>, reaching '
              'your goal around <strong>$goalStr</strong>.',
    ),
    SnapshotCard(
      id: 'timeline',
      icon: '📅',
      type: 'YOUR GOAL',
      accent: 'purple',
      name: 'Timeline',
      value: '$weeks weeks',
      sub: '≈ $goalStr',
      badge: '🏆 Target',
      why: 'Estimated time to reach your goal weight.',
      expandTitle: 'How is this estimate calculated?',
      expand: isMuscle
          ? 'Formula: lean bulk rate of 0.25 kg/week × $weeks weeks = <strong>$weightDelta kg</strong> lean muscle gained. '
              'Your +$deficit kcal/day surplus and consistent resistance training drives this rate. Results vary by training '
              'consistency and protein adherence.'
          : 'Formula: deficit ($deficit kcal/day) × 7 ÷ 7,700 kcal/kg = <strong>$kgPerWeek kg/week</strong>. To lose '
              '$weightDelta kg at that rate = <strong>$weeks weeks</strong>. Results vary by adherence, metabolism, and '
              'lifestyle — this is a science-based estimate, not a guarantee.',
    ),
  ];
}

CoachNote buildDefaultCoachNote(AssessmentCalculations calc, {required bool isMuscle, DateTime? now}) {
  final bStat = bmiInfo(calc.bmi);
  final isHighPriority = calc.bmi >= 30;
  final kgPerWeek = _kgPerWeek(calc.weightDeltaKg, calc.estimatedWeeksToGoal);
  final goalStr = _goalDateLabel(calc.estimatedWeeksToGoal, now: now);
  final opportunity = isMuscle
      ? 'The biggest opportunity right now is creating a <strong>consistent calorie surplus and resistance training stimulus</strong>.'
      : isHighPriority
          ? 'The biggest opportunity right now is creating a <strong>consistent daily calorie deficit</strong>.'
          : calc.bmi >= 25
              ? 'Small, consistent changes will move you into the healthy weight range.'
              : 'You\'re in a healthy range — focus on building strength while maintaining your weight.';

  return CoachNote(
    avatar: '🤖',
    name: 'Zino · AI Nutritionist',
    sub: 'Personalised analysis',
    paragraphs: [
      'Your BMI of <strong>${calc.bmi}</strong> places you in the <strong>${bStat.label}</strong> category. $opportunity',
      'If you hit your daily targets consistently:',
    ],
    bullets: [
      '✓ <strong>${thousands(calc.calorieTargetKcal)} kcal/day</strong> — calorie target',
      '✓ <strong>${thousands(calc.proteinTargetG)}g protein/day</strong> — ${isMuscle ? 'muscle growth' : 'muscle preservation'}',
      '✓ <strong>${thousands(calc.dailyStepsGoal)} steps/day</strong> — daily movement',
      '✓ <strong>${thousands(calc.waterTargetLiters)}L water/day</strong> — metabolism support',
    ],
    result: isMuscle
        ? 'You can realistically gain <strong>~$kgPerWeek kg/week</strong> of lean muscle, reaching your goal around <strong>$goalStr</strong>.'
        : 'You can realistically lose <strong>~$kgPerWeek kg/week</strong>, reaching your goal around <strong>$goalStr</strong>.',
  );
}

// ═══════════════════════════════════════════════════════════════
// GENERAL FITNESS
// ═══════════════════════════════════════════════════════════════

const Map<String, String> kHealthGoalLabels = {
  'energy': 'More Energy',
  'health': 'Better Health',
  'fitness': 'Improve Fitness',
  'habits': 'Healthy Habits',
  'mobility': 'Better Mobility',
  'endurance': 'Better Endurance',
  'strength': 'Better Strength',
  'posture': 'Improve Posture',
  'reduce_stress': 'Reduce Stress',
  'sleep': 'Better Sleep',
};

const Map<String, String> kHealthGoalLong = {
  'energy': 'more energy',
  'health': 'better health',
  'fitness': 'improved fitness',
  'habits': 'healthy habits',
  'mobility': 'better mobility',
  'endurance': 'better endurance',
  'strength': 'better strength',
  'posture': 'improved posture',
  'reduce_stress': 'reduced stress',
  'sleep': 'better sleep',
};

String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

SnapshotSummary buildGeneralFitnessSummary(
  AssessmentCalculations calc, {
  required String fitnessLevel,
}) {
  return SnapshotSummary(
    icon: '❤️',
    heading: 'Your Fitness Targets',
    sub: 'Your daily targets to feel healthier and more energetic',
    items: [
      SnapshotSummaryItem(emoji: '⚡', value: '${thousands(calc.calorieTargetKcal)} kcal', label: 'Maintenance Calories'),
      SnapshotSummaryItem(emoji: '🥩', value: '${thousands(calc.proteinTargetG)}g', label: 'Protein'),
      SnapshotSummaryItem(emoji: '💧', value: '${thousands(calc.waterTargetLiters)}L', label: 'Water'),
      SnapshotSummaryItem(emoji: '👟', value: thousands(calc.dailyStepsGoal), label: 'Steps'),
      SnapshotSummaryItem(emoji: '🌱', value: _capitalize(fitnessLevel), label: 'Fitness Level', highlight: true),
      const SnapshotSummaryItem(emoji: '🗓️', value: '8–12 Weeks', label: 'Est. First Results', highlight: true),
    ],
  );
}

List<SnapshotCard> buildGeneralFitnessCards(
  AssessmentCalculations calc, {
  required String fitnessLevel,
  required List<String> healthGoals,
}) {
  final bStat = bmiInfo(calc.bmi);
  final steps = thousands(calc.dailyStepsGoal);
  final calories = thousands(calc.calorieTargetKcal);
  final protein = thousands(calc.proteinTargetG);
  final water = thousands(calc.waterTargetLiters);
  final tdee = thousands(calc.tdeeKcal.round());
  final bmr = thousands(calc.bmrKcal.round());
  final levelCap = _capitalize(fitnessLevel);
  final goalDisplay = healthGoals.isNotEmpty
      ? healthGoals.take(3).map((g) => kHealthGoalLabels[g] ?? g).join(', ')
      : 'General Fitness';

  return [
    SnapshotCard(
      id: 'bmi',
      icon: '⚖️',
      type: 'CURRENT STATUS',
      accent: bStat.accent,
      name: 'BMI',
      value: '${calc.bmi}',
      sub: bStat.label,
      badge: bStat.badge,
      why: 'A reference measure of your body composition based on height and weight.',
      expandTitle: 'What does my BMI mean for fitness?',
      expand: 'Your BMI of ${calc.bmi} puts you in the <strong>${bStat.label}</strong> category. For general fitness, BMI is '
          'just one indicator — regular exercise, strength, energy, and sleep quality are equally important signals of health.',
    ),
    SnapshotCard(
      id: 'calories',
      icon: '⚡',
      type: 'DAILY TARGET',
      accent: 'orange',
      name: 'Maintenance Calories',
      value: '$calories kcal',
      sub: 'per day',
      badge: '🎯 Daily Target',
      why: 'The calories your body needs to maintain current weight while fuelling exercise.',
      expandTitle: 'Why maintenance calories?',
      expand: 'For general fitness, the goal is <strong>balanced nutrition</strong> — not a deficit or surplus. Your body '
          'burns <strong>$tdee kcal/day</strong>. Eating at this level fuels your workouts, supports recovery, and maintains '
          'a healthy weight.',
    ),
    SnapshotCard(
      id: 'protein',
      icon: '🥩',
      type: 'DAILY TARGET',
      accent: 'orange',
      name: 'Protein Target',
      value: '${protein}g',
      sub: 'per day',
      badge: '🎯 Daily Target',
      why: 'Supports muscle maintenance, recovery after workouts, and sustained energy.',
      expandTitle: 'Why protein for general fitness?',
      expand: 'Protein repairs muscle fibres after every workout and keeps you feeling full and energized throughout the '
          'day. <strong>${protein}g/day</strong> (1.6g/kg) is the optimal amount for active people focused on general '
          'fitness. Sources: eggs, dal, paneer, chicken, curd, soya.',
    ),
    SnapshotCard(
      id: 'water',
      icon: '💧',
      type: 'DAILY TARGET',
      accent: 'blue',
      name: 'Water Intake',
      value: '${water}L',
      sub: 'per day',
      badge: '🎯 Daily Target',
      why: 'Hydration supports energy, workout performance, and recovery.',
      expandTitle: 'Why does water matter for fitness?',
      expand: 'Even mild dehydration reduces exercise performance by 10–20% and causes fatigue. Drink <strong>${water}L/day</strong> '
          '— start with a glass in the morning, drink before every workout, and sip throughout the day.',
    ),
    SnapshotCard(
      id: 'steps',
      icon: '👟',
      type: 'DAILY TARGET',
      accent: 'orange',
      name: 'Daily Steps',
      value: steps,
      sub: 'steps per day',
      badge: '🎯 Daily Target',
      why: 'Daily movement outside the gym — the foundation of an active, healthy lifestyle.',
      expandTitle: 'Why $steps steps?',
      expand: '$steps steps/day builds cardiovascular fitness, improves mood, and keeps metabolism active. Walking is the '
          'single most underrated fitness tool. Take stairs, walk during phone calls, park further away — it all counts.',
    ),
    SnapshotCard(
      id: 'fitness_level',
      icon: '🌱',
      type: 'YOUR PROFILE',
      accent: 'purple',
      name: 'Fitness Level',
      value: levelCap,
      sub: 'starting point',
      badge: '🏆 Your Level',
      why: 'Your starting fitness level shapes the intensity and type of training in your plan.',
      expandTitle: 'How does fitness level affect my plan?',
      expand: 'As a <strong>$levelCap</strong>, your plan is tailored to your starting point. Beginners focus on building '
          'the movement habit and base fitness. Intermediates add variety and challenge. Advanced users work on '
          'functional performance. Your level is reassessed every 8–12 weeks.',
    ),
    SnapshotCard(
      id: 'goals',
      icon: '❤️',
      type: 'YOUR PROFILE',
      accent: 'purple',
      name: 'Health Goals',
      value: goalDisplay,
      sub: 'your focus areas',
      badge: '🏆 Your Goals',
      why: 'Your chosen goals shape your workout and nutrition recommendations.',
      expandTitle: 'How are your goals used?',
      expand: 'Your goals — <strong>$goalDisplay</strong> — are used to select the right exercises, meal timing, and '
          'recovery strategies. Every session in your plan is designed to progress at least one of these areas.',
    ),
    SnapshotCard(
      id: 'timeline',
      icon: '📅',
      type: 'REFERENCE',
      accent: 'info',
      name: 'First Results',
      value: '8–12 Weeks',
      sub: 'for noticeable change',
      badge: 'ℹ️ Reference',
      why: 'Typical timeframe to notice meaningful fitness and energy improvements.',
      expandTitle: 'When will I see results?',
      expand: 'General fitness improvements are cumulative. Expect better energy and mood in <strong>2–3 weeks</strong>. '
          'Noticeable strength and endurance gains in <strong>6–8 weeks</strong>. Clear physical changes in '
          '<strong>10–12 weeks</strong> of consistent training. Stay the course.',
    ),
    SnapshotCard(
      id: 'tdee',
      icon: '⚡',
      type: 'REFERENCE',
      accent: 'info',
      name: 'TDEE',
      value: '$tdee kcal',
      sub: 'daily energy burn',
      badge: 'ℹ️ Reference',
      why: 'Total calories your body burns per day including activity.',
      expandTitle: 'What is TDEE?',
      expand: '<strong>Total Daily Energy Expenditure</strong> — the calories your body burns daily through metabolism, '
          'digestion, and activity. Your maintenance target matches this exactly, fuelling every workout without excess fat '
          'gain or energy deficit.',
    ),
    SnapshotCard(
      id: 'bmr',
      icon: '🧬',
      type: 'REFERENCE',
      accent: 'info',
      name: 'BMR',
      value: '$bmr kcal',
      sub: 'at complete rest',
      badge: 'ℹ️ Reference',
      why: 'Calories your body needs just to stay alive.',
      expandTitle: 'What is BMR?',
      expand: '<strong>Basal Metabolic Rate</strong> — the energy your body needs for breathing, heartbeat, and organ '
          'function even at rest. Never eat below your BMR ($bmr kcal). Your target of $calories kcal is well above this.',
    ),
  ];
}

CoachNote buildGeneralFitnessCoachNote(AssessmentCalculations calc, {required List<String> healthGoals}) {
  final bStat = bmiInfo(calc.bmi);
  final goalLong = healthGoals.isNotEmpty
      ? healthGoals.map((g) => kHealthGoalLong[g] ?? g).join(', ')
      : 'better health and fitness';
  return CoachNote(
    avatar: '🤖',
    name: 'Zino · AI Coach',
    sub: 'Personalised fitness analysis',
    paragraphs: [
      'I want to become <strong>healthier, stronger, fitter and more energetic</strong> — and your plan is built exactly for '
          'that. Your BMI of <strong>${calc.bmi}</strong> (${bStat.label}) is your starting point, not your identity. With '
          'consistency, you\'ll feel a real difference within 8–12 weeks.',
      'Your goals — <strong>$goalLong</strong> — shape everything in this plan. Hit your daily targets:',
    ],
    bullets: [
      '✓ <strong>${thousands(calc.calorieTargetKcal)} kcal/day</strong> — fuel your body at maintenance',
      '✓ <strong>${thousands(calc.proteinTargetG)}g protein/day</strong> — support muscle and recovery',
      '✓ <strong>${thousands(calc.dailyStepsGoal)} steps/day</strong> — build your active lifestyle',
      '✓ <strong>${thousands(calc.waterTargetLiters)}L water/day</strong> — stay energized and focused',
    ],
    result: 'Expect better energy in 2–3 weeks, noticeable fitness gains in 6–8 weeks, and real, visible change by week 12. '
        '<strong>Let\'s build a healthier you.</strong>',
  );
}

// ═══════════════════════════════════════════════════════════════
// TRANSFORMATION
// ═══════════════════════════════════════════════════════════════

SnapshotSummary buildTransformationSummary(AssessmentCalculations calc) {
  return SnapshotSummary(
    icon: '🔥',
    heading: 'Your Transformation Targets',
    sub: 'Daily targets to reveal your lean physique and six pack',
    items: [
      SnapshotSummaryItem(emoji: '🔥', value: '${thousands(calc.calorieTargetKcal)} kcal', label: 'Recomp Calories'),
      SnapshotSummaryItem(emoji: '🥩', value: '${thousands(calc.proteinTargetG)}g', label: 'Protein (2.2g/kg)'),
      SnapshotSummaryItem(emoji: '💧', value: '${thousands(calc.waterTargetLiters)}L', label: 'Water'),
      SnapshotSummaryItem(emoji: '👟', value: thousands(calc.dailyStepsGoal), label: 'Steps'),
      const SnapshotSummaryItem(emoji: '⬡', value: 'Six Pack + Lean', label: 'Transformation Goal', highlight: true),
      const SnapshotSummaryItem(emoji: '🗓️', value: '12–16 Weeks', label: 'Visible Results', highlight: true),
    ],
  );
}

List<SnapshotCard> buildTransformationCards(AssessmentCalculations calc) {
  final bStat = bmiInfo(calc.bmi);
  final steps = thousands(calc.dailyStepsGoal);
  final calories = thousands(calc.calorieTargetKcal);
  final protein = thousands(calc.proteinTargetG);
  final water = thousands(calc.waterTargetLiters);
  final tdee = thousands(calc.tdeeKcal.round());
  final bmr = thousands(calc.bmrKcal.round());

  return [
    SnapshotCard(
      id: 'bmi',
      icon: '⚖️',
      type: 'CURRENT STATUS',
      accent: bStat.accent,
      name: 'BMI',
      value: '${calc.bmi}',
      sub: bStat.label,
      badge: bStat.badge,
      why: 'Body composition baseline. Abs become visible at ~10–14% body fat (men) and ~16–20% (women).',
      expandTitle: 'What does my BMI mean for transformation?',
      expand: 'Your BMI of ${calc.bmi} (${bStat.label}) is your starting point. Transformation is about body composition — '
          'reducing fat % while maintaining or building muscle. BMI is just one signal; waist measurement and progress '
          'photos are more relevant for transformation.',
    ),
    SnapshotCard(
      id: 'calories',
      icon: '🔥',
      type: 'DAILY TARGET',
      accent: 'orange',
      name: 'Recomposition Calories',
      value: '$calories kcal',
      sub: 'per day (mild deficit)',
      badge: '🎯 Daily Target',
      why: 'A mild 250–350 kcal deficit burns fat while preserving the muscle that creates the lean physique.',
      expandTitle: 'Why a mild deficit for transformation?',
      expand: 'Your TDEE is <strong>$tdee kcal/day</strong>. Eating <strong>$calories kcal</strong> creates a mild deficit '
          '— aggressive cutting destroys muscle and slows metabolism. This sweet spot lets you lose fat AND build visible '
          'muscle simultaneously.',
    ),
    SnapshotCard(
      id: 'protein',
      icon: '🥩',
      type: 'DAILY TARGET',
      accent: 'orange',
      name: 'Protein Target',
      value: '${protein}g',
      sub: 'per day (2.2g/kg)',
      badge: '🎯 Daily Target',
      why: 'High protein (2.2g/kg) preserves muscle during the deficit and directly builds lean physique definition.',
      expandTitle: 'Why so much protein for transformation?',
      expand: 'Body recomposition = lose fat + build muscle simultaneously. This requires <strong>${protein}g protein/day</strong> '
          '(2.2g/kg). Protein has the highest thermic effect (burns 25–30% of its own calories), keeps you full, and '
          'directly feeds muscle growth. Sources: eggs, chicken, paneer, dal, curd, soya.',
    ),
    SnapshotCard(
      id: 'water',
      icon: '💧',
      type: 'DAILY TARGET',
      accent: 'blue',
      name: 'Water Intake',
      value: '${water}L',
      sub: 'per day',
      badge: '🎯 Daily Target',
      why: 'Hydration flushes subcutaneous water retention — directly affects how visible your abs look.',
      expandTitle: 'Why does water matter for transformation?',
      expand: 'Paradoxically, drinking more water reduces water retention and makes muscles appear more defined. '
          'Dehydration causes the body to hold water under the skin (bloating) — hiding ab definition. Drink '
          '<strong>${water}L/day</strong> consistently.',
    ),
    SnapshotCard(
      id: 'steps',
      icon: '👟',
      type: 'DAILY TARGET',
      accent: 'orange',
      name: 'Daily Steps (LISS)',
      value: steps,
      sub: 'steps per day',
      badge: '🎯 Daily Target',
      why: 'Low-intensity movement burns fat without burning muscle — the transformation-safe cardio.',
      expandTitle: 'Why steps for body transformation?',
      expand: '$steps steps burns 200–300 kcal/day through LISS (Low Intensity Steady State) — the safest form of calorie '
          'burn during recomposition. Unlike HIIT, walking does not elevate cortisol or interfere with muscle recovery. It '
          'accelerates fat loss without sacrificing gains.',
    ),
    SnapshotCard(
      id: 'timeline',
      icon: '📅',
      type: 'YOUR GOAL',
      accent: 'purple',
      name: 'Transformation Timeline',
      value: '12–16 Weeks',
      sub: 'for visible results',
      badge: '🏆 Target',
      why: 'Standard timeline for visible body transformation with consistent training and nutrition.',
      expandTitle: 'When will I see visible transformation?',
      expand: 'Week 1–4: Metabolic and neural adaptation. Strength increases, minor composition shift. Week 4–8: Visible '
          'fat reduction starts, muscle definition improves. Week 8–12: Abs begin to show, V-taper develops. Week 12–16: '
          'Full visible transformation — lean physique, defined core. Consistency is everything.',
    ),
    SnapshotCard(
      id: 'tdee',
      icon: '⚡',
      type: 'REFERENCE',
      accent: 'info',
      name: 'TDEE',
      value: '$tdee kcal',
      sub: 'maintenance calories',
      badge: 'ℹ️ Reference',
      why: 'Your maintenance level — eat slightly below this to trigger fat loss while building muscle.',
      expandTitle: 'What is TDEE for transformation?',
      expand: '<strong>Total Daily Energy Expenditure</strong> — the calories your body burns daily. Your transformation '
          'target of $calories kcal is 250–350 kcal below this, creating a mild fat-burning deficit while keeping protein '
          'high enough to build or preserve muscle.',
    ),
    SnapshotCard(
      id: 'bmr',
      icon: '🧬',
      type: 'REFERENCE',
      accent: 'info',
      name: 'BMR',
      value: '$bmr kcal',
      sub: 'at complete rest',
      badge: 'ℹ️ Reference',
      why: 'Never eat below your BMR — it destroys muscle, which is the opposite of transformation.',
      expandTitle: 'What is BMR and why does it matter for transformation?',
      expand: '<strong>Basal Metabolic Rate</strong> — the minimum calories your body needs to function. Your target of '
          '$calories kcal is well above your BMR ($bmr kcal), ensuring you burn fat from stored fat — not from muscle '
          'tissue.',
    ),
  ];
}

CoachNote buildTransformationCoachNote(AssessmentCalculations calc) {
  return CoachNote(
    avatar: '🔥',
    name: 'ZITLAS Transformation Coach',
    sub: 'Body recomposition specialist',
    paragraphs: [
      'Your BMI of <strong>${calc.bmi}</strong> (${bmiInfo(calc.bmi).label}) is your current starting point. Transformation '
          'is not about the scale — it\'s about body composition. We\'re going to build visible muscle definition while '
          'systematically losing fat.',
      'Hit your daily transformation targets consistently:',
    ],
    bullets: [
      '✓ <strong>${thousands(calc.calorieTargetKcal)} kcal/day</strong> — mild deficit for fat loss',
      '✓ <strong>${thousands(calc.proteinTargetG)}g protein/day</strong> — muscle preservation + growth (2.2g/kg)',
      '✓ <strong>${thousands(calc.dailyStepsGoal)} steps/day</strong> — LISS cardio for fat burning',
      '✓ <strong>${thousands(calc.waterTargetLiters)}L water/day</strong> — reduces bloating, improves definition',
    ],
    result: 'Expect visible ab definition and a lean physique by <strong>week 12–16</strong>. The transformation starts '
        'today. <strong>Let\'s build the physique you\'ve always wanted.</strong>',
  );
}
