import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../../core/util/json_coerce.dart';
import '../../models/assessment_question.dart';
import '../../models/unit_conversions.dart';
import 'wheel_picker_field.dart';

/// `#s-assess` body for one question — dispatches to the right input type,
/// exactly mirroring `renderQuestion()`'s per-`q.type` branch.
class QuestionView extends StatefulWidget {
  const QuestionView({
    super.key,
    required this.question,
    required this.questionIndex,
    required this.totalQuestions,
    required this.existingAnswer,
    required this.onBack,
    required this.onAnswerAndAdvance,
    required this.onSubmitText,
    required this.onSubmitMultiselect,
    required this.onSetAnswer,
  });

  final AssessmentQuestion question;
  final int questionIndex;
  final int totalQuestions;
  final dynamic existingAnswer;
  final VoidCallback onBack;
  final Future<void> Function(String field, dynamic value) onAnswerAndAdvance;
  final Future<String?> Function(AssessmentQuestion q, String raw) onSubmitText;
  final Future<String?> Function(String field) onSubmitMultiselect;
  final void Function(String field, dynamic value) onSetAnswer;

  @override
  State<QuestionView> createState() => _QuestionViewState();
}

class _QuestionViewState extends State<QuestionView> {
  String? _chosenOption;
  final List<String> _multiSelected = [];
  String? _multiError;
  late double _sliderValue =
      asNum(widget.existingAnswer)?.toDouble() ?? widget.question.defaultVal?.toDouble() ?? 5;
  late final TextEditingController _textController =
      TextEditingController(text: widget.existingAnswer?.toString() ?? '');
  String? _textError;

  // wheel state
  late String _heightUnit = 'cm';
  late String _weightUnit = 'kg';
  num? _wheelValue;

  bool get _isWheelField => kWheelConfig.containsKey(widget.question.field);

  @override
  void initState() {
    super.initState();
    // TYPE-CHECKED, never cast. `existingAnswer` is whatever the athlete
    // previously stored for THIS field, and initState runs for every question
    // type — including the numeric ones. Going BACK re-mounts an already
    // answered question (the ValueKey in assessment_screen.dart carries
    // currentQuestionIndex, so a new State is built), which meant a stored
    // slider/wheel answer hit `as List?` here and crashed the wizard with
    //   type 'int' is not a subtype of type 'List<dynamic>?' in type cast
    // Every wheel field (age, height_cm, weight_kg, goal_weight_kg,
    // sleep_hours, available_time) stores a number, so back-navigation onto
    // any of them was a guaranteed crash. `is List` narrows instead of
    // asserting, and `asNum` tolerates the numeric-as-string values that
    // arrive when an answer round-trips through the website's Firestore doc.
    final existing = widget.existingAnswer;
    if (existing is List) {
      _multiSelected.addAll(existing.where((e) => e != null).map((e) => e.toString()));
    }
    if (_isWheelField) {
      _wheelValue = asNum(existing) ?? kWheelConfig[widget.question.field]!.defaultVal;
    }
  }

  Future<void> _selectOption(String value) async {
    setState(() => _chosenOption = value);
    await Future.delayed(const Duration(milliseconds: 320));
    if (!mounted) return;
    await widget.onAnswerAndAdvance(widget.question.field, value);
  }

  Future<void> _continueMultiselect() async {
    widget.onSetAnswer(widget.question.field, _multiSelected);
    final err = await widget.onSubmitMultiselect(widget.question.field);
    if (mounted) setState(() => _multiError = err);
  }

  Future<void> _continueSlider() async {
    await widget.onAnswerAndAdvance(widget.question.field, _sliderValue.round());
  }

  Future<void> _continueText() async {
    final err = await widget.onSubmitText(widget.question, _textController.text);
    if (mounted) setState(() => _textError = err);
  }

  Future<void> _continueWheel() async {
    await widget.onAnswerAndAdvance(widget.question.field, _wheelValue);
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.question;
    // `pct = Math.round((idx/total)*100)` — pre-increment percentage,
    // reproduced exactly (Question 1 of N shows 0%, not ~(1/N)%).
    final pct = (widget.questionIndex / widget.totalQuestions);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 20, 4),
          child: Row(
            children: [
              IconButton(onPressed: widget.onBack, icon: const Icon(Icons.arrow_back, color: ZitlasTokens.textPrimary)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Question ${widget.questionIndex + 1} of ${widget.totalQuestions}',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: ZitlasTokens.textMuted),
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: pct,
                        minHeight: 5,
                        backgroundColor: ZitlasTokens.bgCardLight,
                        valueColor: const AlwaysStoppedAnimation(ZitlasTokens.primary),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  q.prompt,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary, height: 1.3),
                ),
                if (q.hint != null) ...[
                  const SizedBox(height: 8),
                  Text(q.hint!, style: const TextStyle(fontSize: 13, color: ZitlasTokens.textSecondary, height: 1.4)),
                ],
                const SizedBox(height: 20),
                _buildBody(q),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(AssessmentQuestion q) {
    switch (q.type) {
      case AssessmentQuestionType.options:
        return _buildOptions(q);
      case AssessmentQuestionType.multiselect:
        return _buildMultiselect(q);
      case AssessmentQuestionType.slider:
        return _buildSlider(q);
      case AssessmentQuestionType.text:
        if (q.field == 'height_cm') return _buildHeightWheel();
        if (q.field == 'weight_kg' || q.field == 'goal_weight_kg') return _buildWeightWheel(q.field);
        if (_isWheelField) return _buildPlainWheel(q);
        return _buildText(q);
    }
  }

  Widget _buildOptions(AssessmentQuestion q) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Select one option', style: TextStyle(fontSize: 12, color: ZitlasTokens.textMuted, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        ...q.options.map((opt) {
          final chosen = _chosenOption == opt.value;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GestureDetector(
              onTap: _chosenOption == null ? () => _selectOption(opt.value) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: chosen ? const Color(0x1FFF9800) : ZitlasTokens.bgCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: chosen ? ZitlasTokens.primary : ZitlasTokens.border, width: chosen ? 2 : 1),
                ),
                child: Row(
                  children: [
                    if (opt.icon != null) ...[Text(opt.icon!, style: const TextStyle(fontSize: 20)), const SizedBox(width: 12)],
                    Expanded(
                      child: Text(opt.label, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary)),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildMultiselect(AssessmentQuestion q) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Select all that apply', style: TextStyle(fontSize: 12, color: ZitlasTokens.textMuted, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: q.options.map((opt) {
            final on = _multiSelected.contains(opt.value);
            return GestureDetector(
              onTap: () => setState(() {
                if (on) {
                  _multiSelected.remove(opt.value);
                } else {
                  _multiSelected.add(opt.value);
                }
                if (_multiSelected.isNotEmpty) _multiError = null;
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: on ? const Color(0x1FFF9800) : ZitlasTokens.bgCard,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: on ? ZitlasTokens.primary : ZitlasTokens.border),
                ),
                child: Text(opt.label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: on ? ZitlasTokens.primaryDark : ZitlasTokens.textPrimary)),
              ),
            );
          }).toList(),
        ),
        if (_multiError != null) ...[
          const SizedBox(height: 10),
          Text(_multiError!, style: const TextStyle(color: ZitlasTokens.danger, fontSize: 12.5)),
        ],
        const SizedBox(height: 20),
        _continueButton(_continueMultiselect),
      ],
    );
  }

  Widget _buildSlider(AssessmentQuestion q) {
    return StatefulBuilder(
      builder: (context, setLocal) {
        return Column(
          children: [
            Text('${_sliderValue.round()}', style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w900, color: ZitlasTokens.primary)),
            Slider(
              value: _sliderValue,
              min: q.min!.toDouble(),
              max: q.max!.toDouble(),
              divisions: q.max! - q.min!,
              activeColor: ZitlasTokens.primary,
              onChanged: (v) => setLocal(() => setState(() => _sliderValue = v)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${q.min} (calm)', style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textMuted)),
                  Text('${q.max} (stressed)', style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textMuted)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _continueButton(_continueSlider),
          ],
        );
      },
    );
  }

  Widget _buildText(AssessmentQuestion q) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _textController,
          autofocus: true,
          onChanged: (_) {
            if (_textError != null) setState(() => _textError = null);
          },
          onSubmitted: (_) => _continueText(),
          decoration: InputDecoration(
            hintText: q.placeholder,
            filled: true,
            fillColor: ZitlasTokens.bgCardLight,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            errorText: _textError,
          ),
        ),
        const SizedBox(height: 20),
        _continueButton(_continueText),
      ],
    );
  }

  Widget _buildPlainWheel(AssessmentQuestion q) {
    final cfg = kWheelConfig[q.field]!;
    return Column(
      children: [
        WheelPickerField(
          min: cfg.min,
          max: cfg.max,
          values: cfg.values,
          unit: cfg.unit,
          initialValue: _wheelValue ?? cfg.defaultVal,
          onChanged: (v) => _wheelValue = v,
        ),
        const SizedBox(height: 20),
        _continueButton(_continueWheel),
      ],
    );
  }

  Widget _buildHeightWheel() {
    final cm = (_wheelValue ?? kWheelConfig['height_cm']!.defaultVal).toDouble();
    return Column(
      children: [
        UnitToggle(
          options: const [('cm', 'CM'), ('ftin', 'FT / IN')],
          selected: _heightUnit,
          onSelect: (u) => setState(() => _heightUnit = u),
        ),
        const SizedBox(height: 16),
        if (_heightUnit == 'cm')
          WheelPickerField(
            min: kWheelConfig['height_cm']!.min,
            max: kWheelConfig['height_cm']!.max,
            unit: 'cm',
            initialValue: cm,
            onChanged: (v) => _wheelValue = v,
          )
        else
          Row(
            children: [
              Expanded(
                child: WheelPickerField(
                  min: 3,
                  max: 8,
                  unit: 'ft',
                  initialValue: cmToFt(cm),
                  onChanged: (v) => _wheelValue = ftInToCm(v.toInt(), cmToIn(cm)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: WheelPickerField(
                  min: 0,
                  max: 11,
                  unit: 'in',
                  initialValue: cmToIn(cm),
                  onChanged: (v) => _wheelValue = ftInToCm(cmToFt(cm), v.toInt()),
                ),
              ),
            ],
          ),
        const SizedBox(height: 20),
        _continueButton(_continueWheel),
      ],
    );
  }

  Widget _buildWeightWheel(String field) {
    final cfg = kWheelConfig[field]!;
    final kg = (_wheelValue ?? cfg.defaultVal).toDouble();
    return Column(
      children: [
        UnitToggle(
          options: const [('kg', 'KG'), ('lbs', 'LBS')],
          selected: _weightUnit,
          onSelect: (u) => setState(() => _weightUnit = u),
        ),
        const SizedBox(height: 16),
        if (_weightUnit == 'kg')
          WheelPickerField(
            min: cfg.min,
            max: cfg.max,
            unit: 'kg',
            initialValue: kg,
            onChanged: (v) => _wheelValue = v,
          )
        else
          WheelPickerField(
            min: kgToLbs(cfg.min!.toDouble()),
            max: kgToLbs(cfg.max!.toDouble()),
            unit: 'lbs',
            initialValue: kgToLbs(kg),
            onChanged: (v) => _wheelValue = lbsToKg(v.toInt()),
          ),
        const SizedBox(height: 20),
        _continueButton(_continueWheel),
      ],
    );
  }

  Widget _continueButton(Future<void> Function() onTap) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: ZitlasTokens.primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: const Text('Continue →', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
      ),
    );
  }
}
