import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../../core/utils/safe_image.dart';
import '../../../coaching/models/meal_checkin.dart';
import '../../diet_controller.dart';
import 'meal_confirm_sheet.dart';

/// 📷 Snap Meal — visible ONLY to an athlete with an active Personal Coach.
///
/// An athlete without a coach has nobody to send a photo to, so this widget
/// renders nothing at all rather than a disabled button teasing a feature they
/// cannot use. The gate is re-checked at send time too: a relationship can
/// lapse while the camera is open.
class MealSnapRow extends StatelessWidget {
  const MealSnapRow({
    super.key,
    required this.controller,
    required this.mealName,
    required this.athleteName,
    this.pickPhoto,
  });

  final DietController controller;
  final String mealName;
  final String athleteName;

  /// Injectable for tests; the real one is the device camera / gallery.
  final Future<File?> Function(ImageSource source)? pickPhoto;

  @override
  Widget build(BuildContext context) {
    if (!controller.hasActiveCoach) return const SizedBox.shrink();

    final checkin = controller.checkinFor(mealName);
    if (checkin != null) return _SubmittedMeal(checkin: checkin);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: controller.snappingMeal ? null : () => _snap(context),
          icon: const Icon(Icons.photo_camera_rounded, size: 17),
          label: Text(controller.snappingMeal ? 'Sending…' : 'Snap Meal'),
          style: OutlinedButton.styleFrom(
            foregroundColor: ZitlasTokens.primary,
            side: const BorderSide(color: ZitlasTokens.borderSub),
            padding: const EdgeInsets.symmetric(vertical: 11),
            textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }

  /// Photo → "What is this meal?" → Send to Coach, through the EXISTING
  /// check-in path. Nothing is uploaded until the athlete confirms; upload
  /// errors are shown inside the sheet, which keeps their answer for a retry.
  Future<void> _snap(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final sent = await runMealPhotoFlow(
      context,
      mealName: mealName,
      chooseSource: () => _chooseSource(context),
      pickPhoto: pickPhoto ?? _pickFromDevice,
      send: (photo, mealContext) => controller.submitMealPhoto(
        photo: photo,
        mealName: mealName,
        athleteName: athleteName,
        mealContext: mealContext,
      ),
    );
    if (!sent) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('📷 Sent to your coach for review.'),
        duration: Duration(seconds: 3),
      ));
  }

  Future<ImageSource?> _chooseSource(BuildContext context) {
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: ZitlasTokens.bgCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded, color: ZitlasTokens.primary),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded, color: ZitlasTokens.primary),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  static Future<File?> _pickFromDevice(ImageSource source) async {
    // 2000px is a deliberate FIRST pass — the uploader compresses to 1600px
    // afterwards. Capturing at full sensor resolution first would mean reading
    // a 12MB file off disk just to throw most of it away.
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 2000,
      maxHeight: 2000,
      imageQuality: 90,
    );
    return picked == null ? null : File(picked.path);
  }
}

/// What the athlete sees once a meal has been sent — and once it comes back.
class _SubmittedMeal extends StatelessWidget {
  const _SubmittedMeal({required this.checkin});

  final MealCheckin checkin;

  @override
  Widget build(BuildContext context) {
    final reaction = checkin.reaction;
    final reviewed = reaction != null;
    final tint = !reviewed
        ? ZitlasTokens.textSecondary
        : (reaction.isCompliant ? ZitlasTokens.success : ZitlasTokens.danger);

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tint.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isNetworkImageUrl(checkin.imageUrl))
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: CachedNetworkImage(
                imageUrl: checkin.imageUrl!,
                width: 46,
                height: 46,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => Container(
                  width: 46,
                  height: 46,
                  color: ZitlasTokens.bgCardLight,
                  child: const Icon(Icons.image_not_supported_rounded,
                      size: 16, color: ZitlasTokens.textMuted),
                ),
              ),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reviewed
                      ? '${reaction.icon} ${reaction.label}'
                      : '⏳ Sent — waiting for your coach',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: reviewed ? tint : ZitlasTokens.textSecondary,
                  ),
                ),
                if (checkin.comment != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    '"${checkin.comment!}"',
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      fontStyle: FontStyle.italic,
                      color: ZitlasTokens.textSecondary,
                    ),
                  ),
                ],
                if (checkin.hasEstimate) ...[
                  const SizedBox(height: 3),
                  Text(
                    // Labelled as an estimate, because it is one — a vision
                    // model looking at a plate, not a weighed measurement.
                    'Estimated ${[
                      if (checkin.estimatedCalories != null)
                        '${checkin.estimatedCalories!.round()} kcal',
                      if (checkin.estimatedProtein != null)
                        '${checkin.estimatedProtein!.round()}g protein',
                    ].join(' · ')}',
                    style: const TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
