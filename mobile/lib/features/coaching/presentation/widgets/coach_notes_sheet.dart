import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../expert_dashboard/data/expert_repository.dart';

/// Private coach notes on one athlete (Step 8).
///
/// Stored at `experts/{coachId}/athlete_notes/{athleteId}` — under the COACH.
/// `coaching_plans/{athleteUid}` is readable by the athlete, so a note kept
/// there would be visible to the person it is about; Security Rules grant this
/// subcollection to its owner alone.
Future<void> showCoachNotesSheet(
  BuildContext context, {
  required String athleteId,
  required String coachId,
  required ExpertRepository repository,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CoachNotesSheet(
      athleteId: athleteId,
      coachId: coachId,
      repository: repository,
    ),
  );
}

class _CoachNotesSheet extends StatefulWidget {
  const _CoachNotesSheet({
    required this.athleteId,
    required this.coachId,
    required this.repository,
  });

  final String athleteId;
  final String coachId;
  final ExpertRepository repository;

  @override
  State<_CoachNotesSheet> createState() => _CoachNotesSheetState();
}

class _CoachNotesSheetState extends State<_CoachNotesSheet> {
  final _controller = TextEditingController();
  bool _seeded = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.repository.saveCoachNote(
        coachId: widget.coachId,
        athleteId: widget.athleteId,
        note: _controller.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save the note. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: ZitlasTokens.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
        child: StreamBuilder<String?>(
          stream: widget.repository.watchCoachNote(
            coachId: widget.coachId,
            athleteId: widget.athleteId,
          ),
          builder: (context, snap) {
            // Seeded once. Re-seeding on every snapshot would overwrite what
            // the coach is currently typing the moment the write echoes back.
            if (!_seeded && snap.connectionState != ConnectionState.waiting) {
              _controller.text = snap.data ?? '';
              _seeded = true;
            }

            return Column(
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
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.lock_rounded, size: 15, color: ZitlasTokens.textSecondary),
                    const SizedBox(width: 7),
                    const Text(
                      'Private notes',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: ZitlasTokens.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                const Text(
                  'Only you can see these. They are stored against your coach '
                  'profile, not the user\'s — the user has no way to read them.',
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: ZitlasTokens.textSecondary),
                ),
                const SizedBox(height: 14),
                if (snap.connectionState == ConnectionState.waiting)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 30),
                    child: Center(
                      child: CircularProgressIndicator(color: ZitlasTokens.primary),
                    ),
                  )
                else
                  TextField(
                    controller: _controller,
                    maxLines: 8,
                    minLines: 5,
                    autofocus: true,
                    style: const TextStyle(fontSize: 13, height: 1.45),
                    decoration: InputDecoration(
                      hintText:
                          'Injuries, what has worked, what to watch, things said in '
                          'conversation you want to remember…',
                      hintStyle: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textMuted),
                      filled: true,
                      fillColor: ZitlasTokens.bgCardLight,
                      contentPadding: const EdgeInsets.all(13),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(13),
                        borderSide: const BorderSide(color: ZitlasTokens.borderSub),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(13),
                        borderSide: const BorderSide(color: ZitlasTokens.borderSub),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(13),
                        borderSide: const BorderSide(color: ZitlasTokens.primary),
                      ),
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: const TextStyle(fontSize: 12, color: ZitlasTokens.danger),
                  ),
                ],
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: ZitlasTokens.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
                    ),
                    child: Text(
                      _saving ? 'Saving…' : 'Save note',
                      style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
