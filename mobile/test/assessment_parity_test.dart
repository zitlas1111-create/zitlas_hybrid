import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/assessment/models/assessment_question.dart';

/// THE TWO SURVEYS MUST ASK THE SAME THINGS.
///
/// The website's question banks (`QUESTIONS`, `GF_QUESTIONS`, `TF_QUESTIONS`
/// in `pages/dashboard/ai-coach/ai-coach.js`) and Flutter's
/// (`defaultQuestions`, `generalFitnessQuestions`, `transformationQuestions`)
/// are hand-maintained parallel copies. Nothing structural keeps them in step,
/// and a field added to one and forgotten in the other produces a plan built
/// from different information depending on which device the athlete used —
/// silently, with no error anywhere.
///
/// This test reads the real JavaScript file and compares the field lists.
void main() {
  /// The website source, or null when the repo layout puts it out of reach
  /// (a packaged test run, say). Skipping is correct there: this asserts a
  /// cross-repo invariant, not app behaviour.
  String? websiteSource() {
    for (final path in [
      '../frontend/website/pages/dashboard/ai-coach/ai-coach.js',
      'frontend/website/pages/dashboard/ai-coach/ai-coach.js',
    ]) {
      final f = File(path);
      if (f.existsSync()) return f.readAsStringSync();
    }
    return null;
  }

  /// Field names, in order, from one `var NAME = [ ... ];` block.
  List<String> webFields(String src, String varName) {
    final start = src.indexOf('var $varName = [');
    expect(start, isNot(-1), reason: '$varName not found in ai-coach.js');
    final end = src.indexOf('\n  ];', start);
    return RegExp("field: '([a-z_]+)'")
        .allMatches(src.substring(start, end))
        .map((m) => m.group(1)!)
        .toList();
  }

  List<String> flutterFields(List<AssessmentQuestion> qs) =>
      qs.map((q) => q.field).toList();

  final pairs = <String, (String, List<AssessmentQuestion>)>{
    'weight loss / muscle gain': ('QUESTIONS', defaultQuestions),
    'general fitness': ('GF_QUESTIONS', generalFitnessQuestions),
    'transformation': ('TF_QUESTIONS', transformationQuestions),
  };

  /// A KNOWN, INTENTIONAL difference — not drift.
  ///
  /// Flutter asks these two inline; the website collects the same answers in
  /// its separate nutrition step. Both end up in the same payload fields, so
  /// the backend cannot tell the difference. They are excluded by name rather
  /// than by loosening the comparison, so any NEW divergence still fails.
  const knownFlutterOnly = {'favorite_foods', 'supplements_used'};

  group('web and Flutter ask the same questions', () {
    for (final entry in pairs.entries) {
      test('${entry.key} — same fields, same order', () {
        final src = websiteSource();
        if (src == null) {
          markTestSkipped('website source not reachable from this run');
          return;
        }
        final (varName, questions) = entry.value;
        final flutter = flutterFields(questions)
            .where((f) => !knownFlutterOnly.contains(f))
            .toList();
        expect(flutter, webFields(src, varName),
            reason: 'the ${entry.key} survey has drifted between platforms — '
                'an athlete would get a plan built from different answers '
                'depending on which device they used');
      });
    }

    test('the known platform difference is exactly the nutrition pair', () {
      // If this fails, something new diverged and was quietly waved through
      // by the exclusion above.
      final src = websiteSource();
      if (src == null) {
        markTestSkipped('website source not reachable from this run');
        return;
      }
      final onlyInFlutter = <String>{};
      for (final entry in pairs.entries) {
        final (varName, questions) = entry.value;
        final web = webFields(src, varName).toSet();
        onlyInFlutter
            .addAll(flutterFields(questions).where((f) => !web.contains(f)));
      }
      expect(onlyInFlutter, knownFlutterOnly);
    });
  });

  group('the fitness-readiness questions', () {
    test('weight loss / muscle gain asks experience, stairs and walking', () {
      final f = flutterFields(defaultQuestions);
      expect(f, contains('workout_experience'));
      expect(f, contains('stair_ability'));
      expect(f, contains('walk_ability'),
          reason: 'walking is the primary fat-loss modality');
    });

    test('transformation asks experience, stairs and squats', () {
      final f = flutterFields(transformationQuestions);
      expect(f, contains('workout_experience'));
      expect(f, contains('stair_ability'));
      expect(f, contains('squat_ability'),
          reason: 'body recomposition leans on strength work');
    });

    test('general fitness does NOT get a second experience question', () {
      // It already asks `fitness_level`. Asking both would be the duplicate
      // the spec explicitly forbids.
      final f = flutterFields(generalFitnessQuestions);
      expect(f, contains('fitness_level'));
      expect(f, isNot(contains('workout_experience')));
      expect(f, contains('stair_ability'),
          reason: 'what it lacked was a practical answer, not a claim');
    });

    test('no flow asks a second daily-activity question', () {
      for (final qs in [
        defaultQuestions,
        generalFitnessQuestions,
        transformationQuestions
      ]) {
        final activity =
            flutterFields(qs).where((f) => f == 'activity_level').length;
        expect(activity, 1, reason: 'activity is asked exactly once');
      }
    });

    test('no flow asks the same field twice', () {
      for (final entry in pairs.entries) {
        final f = flutterFields(entry.value.$2);
        expect(f.toSet().length, f.length,
            reason: '${entry.key} has a duplicate question');
      }
    });

    test('the survey stayed short — at most 3 questions were added', () {
      // "Ask less, understand more." Counts before this change: 15 / 14 / 16.
      // Flutter counts include the two nutrition questions the website asks
      // in a separate step (see knownFlutterOnly): 17 -> 20, 16 -> 17, 18 -> 21.
      expect(defaultQuestions.length, lessThanOrEqualTo(20));
      expect(generalFitnessQuestions.length, lessThanOrEqualTo(17));
      expect(transformationQuestions.length, lessThanOrEqualTo(21));
    });
  });

  group('the questions read like a person talking', () {
    final readiness = [
      ...defaultQuestions,
      ...generalFitnessQuestions,
      ...transformationQuestions,
    ].where((q) => const {
          'workout_experience',
          'stair_ability',
          'walk_ability',
          'squat_ability',
        }.contains(q.field));

    test('every option has an emoji and plain-language copy', () {
      for (final q in readiness) {
        expect(q.options, isNotEmpty, reason: q.field);
        for (final o in q.options) {
          expect(o.icon, isNotNull, reason: '${q.field} / ${o.label}');
          expect(o.label.length, lessThan(40),
              reason: 'long labels read as an exam: ${o.label}');
        }
      }
    });

    test('no clinical or technical wording', () {
      const banned = [
        'perceived exertion',
        'cardiovascular',
        'capacity',
        'assess',
        'rate your',
        'workout capability',
        'body currently handle',
      ];
      for (final q in readiness) {
        final text =
            '${q.prompt} ${q.options.map((o) => o.label).join(' ')}'.toLowerCase();
        for (final phrase in banned) {
          expect(text.contains(phrase), isFalse,
              reason: '"${q.prompt}" uses clinical wording: $phrase');
        }
      }
    });

    test('the normalized values match what the backend resolves', () {
      // backend/services/fitness_stage.py's maps. A value the resolver does
      // not recognise contributes nothing — it would silently weaken the
      // result rather than fail.
      const abilityValues = {'easy', 'okay', 'tired', 'difficult'};
      const experienceValues = {
        'beginner',
        'novice',
        'intermediate',
        'advanced'
      };
      for (final q in readiness) {
        final expected =
            q.field == 'workout_experience' ? experienceValues : abilityValues;
        for (final o in q.options) {
          expect(expected, contains(o.value),
              reason: '${q.field} sends "${o.value}", which fitness_stage.py '
                  'does not recognise');
        }
      }
    });
  });
}
