import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../data/expert_rating_repository.dart';
import '../../models/expert_rating.dart';
import 'hide_face_editor.dart';

/// "How was your experience?" — the post-engagement rating sheet.
///
/// Returns true only when a rating was actually submitted. Dismissal
/// returns null and MUST NOT be treated as a review: the engagement stays
/// pending so the athlete can be asked again later.
Future<bool?> showRateExpertSheet(
  BuildContext context, {
  required PendingExpertRating pending,
  ExpertRatingRepository? repository,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // Dismissible by design — "Maybe later" is a legitimate answer and
    // keeps the engagement pending rather than marking it reviewed.
    isDismissible: true,
    builder: (_) => _RateExpertSheet(
      pending: pending,
      repository: repository ?? ExpertRatingRepository(),
    ),
  );
}

class _RateExpertSheet extends StatefulWidget {
  const _RateExpertSheet({required this.pending, required this.repository});

  final PendingExpertRating pending;
  final ExpertRatingRepository repository;

  @override
  State<_RateExpertSheet> createState() => _RateExpertSheetState();
}

class _RateExpertSheetState extends State<_RateExpertSheet> {
  late final ExpertRatingDraft _draft = ExpertRatingDraft(
    engagementId: widget.pending.engagementId,
    expertId: widget.pending.expertId,
  );
  final _textController = TextEditingController();
  final _picker = ImagePicker();

  File? _beforeFile;
  File? _afterFile;
  Uint8List? _beforeEdited;
  Uint8List? _afterEdited;

  bool _submitting = false;
  bool _done = false;
  String? _error;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _pick({required bool isBefore}) async {
    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (picked == null || !mounted) return;
    setState(() {
      if (isBefore) {
        _beforeFile = File(picked.path);
        _beforeEdited = null;
      } else {
        _afterFile = File(picked.path);
        _afterEdited = null;
      }
    });
  }

  Future<void> _hideFace({required bool isBefore}) async {
    final file = isBefore ? _beforeFile : _afterFile;
    if (file == null) return;
    final edited = await showHideFaceEditor(context, file);
    if (edited == null || !mounted) return;
    setState(() {
      if (isBefore) {
        _beforeEdited = edited;
      } else {
        _afterEdited = edited;
      }
    });
  }

  void _remove({required bool isBefore}) {
    setState(() {
      if (isBefore) {
        _beforeFile = null;
        _beforeEdited = null;
      } else {
        _afterFile = null;
        _afterEdited = null;
      }
      // Consent is meaningless with no photos left.
      if (_beforeFile == null && _afterFile == null) _draft.photoPublic = false;
    });
  }

  Future<void> _submit() async {
    if (!_draft.canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    _draft.reviewText = _textController.text;

    // Photos first. A failure here drops the photo and CONTINUES — the
    // athlete's rating and written feedback must never be lost to a flaky
    // upload (spec item 24).
    final photoWarnings = <String>[];
    for (final (file, edited, isBefore) in [
      (_beforeFile, _beforeEdited, true),
      (_afterFile, _afterEdited, false),
    ]) {
      if (file == null) continue;
      try {
        final url = await widget.repository.uploadPhoto(file, bytes: edited);
        if (isBefore) {
          _draft.beforePhotoUrl = url;
        } else {
          _draft.afterPhotoUrl = url;
        }
      } on TransformationPhotoException catch (e) {
        photoWarnings.add(e.message);
      }
    }

    try {
      await widget.repository.submit(_draft);
    } catch (e) {
      // "Already rated" means the athlete's goal is met — treat it as done
      // rather than showing an error for something that is not a problem.
      if (!ExpertRatingRepository.isAlreadyRated(e)) {
        if (!mounted) return;
        setState(() {
          _submitting = false;
          _error = "We couldn't submit your review. Please try again.";
        });
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _submitting = false;
      _done = true;
    });
    if (photoWarnings.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(photoWarnings.first)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.92),
        decoration: const BoxDecoration(
          color: ZitlasTokens.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: SingleChildScrollView(
          child: _done ? _buildSuccess() : _buildForm(),
        ),
      ),
    );
  }

  Widget _buildSuccess() {
    final sharedPublicly = _draft.photoPublic && _draft.hasAnyPhoto;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Grabber(),
        const SizedBox(height: 8),
        const Text('Thanks for your feedback! ❤️', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
        const SizedBox(height: 8),
        Text(
          "Your review has been added to ${widget.pending.expertName}'s profile.",
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: ZitlasTokens.textSecondary, height: 1.4),
        ),
        if (sharedPublicly) ...[
          const SizedBox(height: 8),
          const Text(
            'Your transformation story can help inspire others.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: ZitlasTokens.primaryDark, fontWeight: FontWeight.w600),
          ),
        ],
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: ZitlasTokens.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Widget _buildForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Center(child: _Grabber()),
        const SizedBox(height: 6),
        const Text('How was your experience?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
        const SizedBox(height: 4),
        Text(
          'Rate your experience with ${widget.pending.expertName}',
          style: const TextStyle(fontSize: 13, color: ZitlasTokens.textSecondary),
        ),
        const SizedBox(height: 16),
        _StarRow(
          rating: _draft.rating,
          onChanged: (v) => setState(() => _draft.rating = v),
        ),
        const SizedBox(height: 20),

        const _Label('Optional: What did you like about your expert?'),
        const SizedBox(height: 6),
        TextField(
          controller: _textController,
          maxLines: 4,
          maxLength: 1000,
          decoration: InputDecoration(
            hintText: 'Tell us what you liked about their guidance, support, communication, plan, etc.',
            hintStyle: const TextStyle(fontSize: 12.5),
            filled: true,
            fillColor: ZitlasTokens.bgCardLight,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 8),

        const _Label('Want to share your progress?'),
        const SizedBox(height: 2),
        const Text(
          'Show your transformation and inspire others.',
          style: TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _PhotoSlot(
                label: 'Before',
                file: _beforeFile,
                edited: _beforeEdited,
                onPick: () => _pick(isBefore: true),
                onHideFace: () => _hideFace(isBefore: true),
                onRemove: () => _remove(isBefore: true),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _PhotoSlot(
                label: 'After',
                file: _afterFile,
                edited: _afterEdited,
                onPick: () => _pick(isBefore: false),
                onHideFace: () => _hideFace(isBefore: false),
                onRemove: () => _remove(isBefore: false),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // ALWAYS shown, whether or not a photo has been picked yet.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: ZitlasTokens.bgCardLight,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                '🔒 You can hide your face before sharing your photo.',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary),
              ),
              SizedBox(height: 2),
              Text(
                'Blur or cover your face for extra privacy.',
                style: TextStyle(fontSize: 11.5, color: ZitlasTokens.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // Explicit, separate, OFF by default. Never implied by uploading.
        Semantics(
          checked: _draft.photoPublic,
          child: InkWell(
            onTap: _draft.hasPhotoSelected(_beforeFile, _afterFile)
                ? () => setState(() => _draft.photoPublic = !_draft.photoPublic)
                : null,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: _draft.photoPublic,
                    onChanged: _draft.hasPhotoSelected(_beforeFile, _afterFile)
                        ? (v) => setState(() => _draft.photoPublic = v ?? false)
                        : null,
                    activeColor: ZitlasTokens.primary,
                  ),
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'I allow ZITLAS to display these transformation photos on this expert’s profile.',
                        style: TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary, height: 1.35),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.danger)),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: ZitlasTokens.textSecondary,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Maybe later'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                // Rating is REQUIRED — disabled until a star is chosen.
                onPressed: (_submitting || !_draft.canSubmit) ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: ZitlasTokens.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: ZitlasTokens.border,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Submit Review', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

extension on ExpertRatingDraft {
  bool hasPhotoSelected(File? before, File? after) => before != null || after != null;
}

class _StarRow extends StatelessWidget {
  const _StarRow({required this.rating, required this.onChanged});
  final int rating;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 1; i <= 5; i++)
            Semantics(
              button: true,
              selected: rating >= i,
              // Reads as "3 stars", never an unlabelled icon.
              label: '$i ${i == 1 ? 'star' : 'stars'}',
              child: IconButton(
                onPressed: () => onChanged(i),
                // Comfortable target on a phone, well above the 48dp min.
                iconSize: 38,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
                icon: Icon(
                  rating >= i ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: rating >= i ? const Color(0xFFF5A623) : ZitlasTokens.border,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PhotoSlot extends StatelessWidget {
  const _PhotoSlot({
    required this.label,
    required this.file,
    required this.edited,
    required this.onPick,
    required this.onHideFace,
    required this.onRemove,
  });

  final String label;
  final File? file;
  final Uint8List? edited;
  final VoidCallback onPick;
  final VoidCallback onHideFace;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    if (file == null) {
      return Semantics(
        button: true,
        label: 'Add $label photo, optional',
        child: InkWell(
          onTap: onPick,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: 104,
            decoration: BoxDecoration(
              color: ZitlasTokens.bgCardLight,
              border: Border.all(color: ZitlasTokens.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.add_a_photo_outlined, size: 20, color: ZitlasTokens.textMuted),
                const SizedBox(height: 6),
                Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ZitlasTokens.textSecondary)),
                const Text('Optional', style: TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted)),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 104,
            width: double.infinity,
            child: edited != null
                ? Image.memory(edited!, fit: BoxFit.cover)
                : Image.file(file!, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton(
              onPressed: onHideFace,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 36),
                foregroundColor: ZitlasTokens.primaryDark,
              ),
              child: Text(
                edited != null ? '🔒 Face hidden' : 'Hide Face',
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
              ),
            ),
            TextButton(
              onPressed: onRemove,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 36),
                foregroundColor: ZitlasTokens.textMuted,
              ),
              child: const Text('Remove', style: TextStyle(fontSize: 11.5)),
            ),
          ],
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary),
      );
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(color: ZitlasTokens.border, borderRadius: BorderRadius.circular(4)),
      );
}
