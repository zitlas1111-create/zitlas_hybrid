import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../coaching/models/meal_context.dart';

/// The athlete's in-progress answer to "What is this meal?".
///
/// Owned by [runMealPhotoFlow] rather than the sheet, so it survives Change
/// Photo and a failed send — the athlete never re-picks what they chose.
class MealDraft {
  final List<String> selected = [];
  bool otherSelected = false;
  String customText = '';
}

/// How the confirmation step ended.
enum MealConfirmOutcome { sent, changePhoto, cancelled }

/// The whole meal-photo step:
///
///     choose camera/gallery → photo → "What is this meal?" → Send to Coach
///
/// NOTHING is uploaded until Send to Coach — backing out at any point sends
/// nothing. Change Photo re-opens the picker and keeps the answer; cancelling
/// that picker keeps the photo already chosen. Returns true once sent.
///
/// [send] is the EXISTING check-in path (DietController.submitMealPhoto): it
/// returns null on success or a message to show, and on a message the sheet
/// stays open with everything chosen, so retrying is one tap.
Future<bool> runMealPhotoFlow(
  BuildContext context, {
  required String mealName,
  required Future<ImageSource?> Function() chooseSource,
  required Future<File?> Function(ImageSource source) pickPhoto,
  required Future<String?> Function(File photo, MealContext mealContext) send,
}) async {
  final draft = MealDraft();
  File? photo;
  while (true) {
    final source = await chooseSource();
    if (!context.mounted) return false;
    final picked = source == null ? null : await pickPhoto(source);
    if (!context.mounted) return false;
    if (picked != null) photo = picked;
    final current = photo;
    if (current == null) return false; // nothing was ever taken

    final outcome = await showMealConfirmSheet(
      context,
      photo: current,
      mealName: mealName,
      draft: draft,
      onSend: (mealContext) => send(current, mealContext),
    );
    if (outcome == MealConfirmOutcome.sent) return true;
    if (outcome == MealConfirmOutcome.cancelled || !context.mounted) return false;
    // changePhoto: round again, answer intact.
  }
}

Future<MealConfirmOutcome> showMealConfirmSheet(
  BuildContext context, {
  required File photo,
  required String mealName,
  required MealDraft draft,
  required Future<String?> Function(MealContext mealContext) onSend,
}) async {
  final outcome = await showModalBottomSheet<MealConfirmOutcome>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => MealConfirmSheet(
      photo: photo,
      mealName: mealName,
      draft: draft,
      onSend: onSend,
    ),
  );
  return outcome ?? MealConfirmOutcome.cancelled;
}

/// "What is this meal?" — photo, one-tap foods, and "Other" for anything else.
///
/// The common case is photo → Chicken → Rice → Send, with no typing. Several
/// foods can be picked; each is removable before sending.
class MealConfirmSheet extends StatefulWidget {
  const MealConfirmSheet({
    super.key,
    required this.photo,
    required this.mealName,
    required this.draft,
    required this.onSend,
  });

  final File photo;
  final String mealName;
  final MealDraft draft;
  final Future<String?> Function(MealContext mealContext) onSend;

  @override
  State<MealConfirmSheet> createState() => _MealConfirmSheetState();
}

class _MealConfirmSheetState extends State<MealConfirmSheet> {
  late final TextEditingController _custom =
      TextEditingController(text: widget.draft.customText);
  String? _error;
  bool _sending = false;

  MealDraft get _d => widget.draft;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _toggle(String item) {
    setState(() {
      _error = null;
      if (!_d.selected.remove(item)) _d.selected.add(item);
    });
  }

  void _toggleOther() {
    setState(() {
      _error = null;
      _d.otherSelected = !_d.otherSelected;
    });
  }

  Future<void> _send() async {
    if (_sending) return;
    _d.customText = _custom.text;
    final built = buildMealContext(
      selected: _d.selected,
      otherSelected: _d.otherSelected,
      customText: _custom.text,
    );
    if (built.error != null) {
      setState(() => _error = built.error);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final failure = await widget.onSend(built.context!);
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(MealConfirmOutcome.sent);
      return;
    }
    // Everything the athlete chose stays exactly as it was: retry is one tap.
    setState(() {
      _sending = false;
      _error = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Keeps the custom-name field and the Send button above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: ZitlasTokens.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: ZitlasTokens.borderSub,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        widget.photo,
                        key: const Key('mealConfirmPhoto'),
                        width: 76,
                        height: 76,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 76,
                          height: 76,
                          color: ZitlasTokens.bgCardLight,
                          child: const Icon(Icons.restaurant_rounded,
                              color: ZitlasTokens.textMuted),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'What is this meal?',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: ZitlasTokens.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 3),
                          const Text(
                            "Tell your coach what you're eating.",
                            style: TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            widget.mealName,
                            style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item in kMealQuickItems)
                      _MealChip(
                        key: Key('mealChip_$item'),
                        label: item,
                        selected: _d.selected.contains(item),
                        onTap: _sending ? null : () => _toggle(item),
                      ),
                    _MealChip(
                      key: const Key('mealChip_Other'),
                      label: 'Other',
                      selected: _d.otherSelected,
                      onTap: _sending ? null : _toggleOther,
                    ),
                  ],
                ),
                if (_d.selected.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        'Selected:',
                        style: TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary),
                      ),
                      for (final item in _d.selected)
                        InputChip(
                          key: Key('mealSelected_$item'),
                          label: Text(item),
                          onDeleted: _sending ? null : () => _toggle(item),
                          deleteButtonTooltipMessage: 'Remove $item',
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ],
                if (_d.otherSelected) ...[
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('mealCustomField'),
                    controller: _custom,
                    autofocus: true,
                    enabled: !_sending,
                    maxLength: kMealCustomMaxLength,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) {
                      _d.customText = _custom.text;
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      labelText: 'Enter meal name',
                      hintText: 'e.g. Chicken biryani, Poha, Idli sambar',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    key: const Key('mealConfirmError'),
                    style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.danger),
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  children: [
                    TextButton.icon(
                      key: const Key('mealChangePhoto'),
                      onPressed: _sending
                          ? null
                          : () => Navigator.of(context).pop(MealConfirmOutcome.changePhoto),
                      icon: const Icon(Icons.photo_camera_rounded, size: 17),
                      label: const Text('Change Photo'),
                    ),
                    const Spacer(),
                    FilledButton(
                      key: const Key('mealSendToCoach'),
                      style: FilledButton.styleFrom(
                        backgroundColor: ZitlasTokens.primary,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      ),
                      onPressed: _sending ? null : _send,
                      child: Text(_sending ? 'Sending…' : 'Send to Coach'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MealChip extends StatelessWidget {
  const _MealChip({super.key, required this.label, required this.selected, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? ZitlasTokens.primary : ZitlasTokens.bgCardLight,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected ? ZitlasTokens.primary : ZitlasTokens.borderSub,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  const Icon(Icons.check_rounded, size: 15, color: Colors.white),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : ZitlasTokens.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
