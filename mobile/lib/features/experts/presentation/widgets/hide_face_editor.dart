import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../../core/theme/zitlas_tokens.dart';

/// "Hide Face" — drag a privacy cover over the face, preview it, confirm.
///
/// WHY MANUAL, NOT AUTOMATIC FACE DETECTION: ZITLAS ships no face-detection
/// capability (checked `pubspec.yaml` — `image_picker` and
/// `flutter_image_compress` are the only imaging packages; there is no ML
/// Kit / vision dependency), so automatic detection is not "technically
/// supported by the existing Flutter architecture" without adding a large
/// native ML dependency.
///
/// That constraint turns out to favour the safer design anyway. Automatic
/// detection fails *silently* — a missed face means a transformation photo
/// published with the athlete's face exposed, which is exactly the harm this
/// control exists to prevent. A cover the athlete places and visually
/// confirms cannot fail that way: what they see in the preview is literally
/// the pixels that get uploaded.
///
/// The edited image is rasterised from the preview itself
/// (`RepaintBoundary.toImage`), so the uploaded bytes and the confirmed
/// preview are the same render — the original is never uploaded once the
/// athlete has chosen to hide their face.
Future<Uint8List?> showHideFaceEditor(BuildContext context, File photo) {
  return showModalBottomSheet<Uint8List>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _HideFaceEditor(photo: photo),
  );
}

class _HideFaceEditor extends StatefulWidget {
  const _HideFaceEditor({required this.photo});
  final File photo;

  @override
  State<_HideFaceEditor> createState() => _HideFaceEditorState();
}

class _HideFaceEditorState extends State<_HideFaceEditor> {
  final _boundaryKey = GlobalKey();

  /// Cover centre as a FRACTION of the displayed image (0-1), so it stays
  /// correct regardless of the widget's laid-out size or the device.
  Offset _center = const Offset(0.5, 0.22);
  double _radiusFraction = 0.16;
  bool _saving = false;

  Future<void> _confirm() async {
    setState(() => _saving = true);
    try {
      final boundary =
          _boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      // 2x so the uploaded image isn't degraded to on-screen resolution.
      final image = await boundary.toImage(pixelRatio: 2.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (!mounted) return;
      Navigator.of(context).pop(data?.buffer.asUint8List());
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't apply the cover — you can still use the original photo.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
      decoration: const BoxDecoration(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: ZitlasTokens.border,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const Text(
              '🔒 Hide your face',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
            ),
            const SizedBox(height: 4),
            const Text(
              'Drag the cover over your face, then resize it. What you see here is exactly what gets uploaded.',
              style: TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                return Semantics(
                  label: 'Photo with a privacy cover. Drag to move the cover over your face.',
                  child: GestureDetector(
                    onPanUpdate: (d) => setState(() {
                      _center = Offset(
                        (_center.dx + d.delta.dx / w).clamp(0.0, 1.0),
                        (_center.dy + d.delta.dy / w).clamp(0.0, 1.0),
                      );
                    }),
                    child: RepaintBoundary(
                      key: _boundaryKey,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Image.file(widget.photo, width: w, fit: BoxFit.fitWidth),
                            // The cover itself. Opaque rather than a blur:
                            // a blur strong enough to be safe still leaks
                            // face shape and skin tone, and a weak one
                            // gives false confidence.
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _CoverPainter(
                                  center: _center,
                                  radiusFraction: _radiusFraction,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            const Text(
              'Cover size',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ZitlasTokens.textMuted),
            ),
            Slider(
              value: _radiusFraction,
              min: 0.06,
              max: 0.40,
              activeColor: ZitlasTokens.primary,
              label: 'Cover size',
              onChanged: (v) => setState(() => _radiusFraction = v),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ZitlasTokens.textSecondary,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _confirm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ZitlasTokens.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Use this photo', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverPainter extends CustomPainter {
  const _CoverPainter({required this.center, required this.radiusFraction});

  final Offset center;
  final double radiusFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(center.dx * size.width, center.dy * size.width);
    final r = radiusFraction * size.width;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF1A1A1A));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_CoverPainter old) =>
      old.center != center || old.radiusFraction != radiusFraction;
}
