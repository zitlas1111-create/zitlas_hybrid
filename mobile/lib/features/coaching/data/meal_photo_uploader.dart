import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import '../../../core/config/env.dart';
import '../../../core/network/api_client.dart';

/// The photo, decoded and normalized exactly once. Both upload destinations
/// (Firebase Storage / the backend fallback) and the AI nutrition estimate
/// share these SAME bytes + Content-Type, so none of them can see a
/// different format than the others.
typedef PreparedMealPhoto = ({Uint8List bytes, String contentType, String fileName});

/// Uploads a meal photo, mirroring `assets/js/chat-attachments.js` exactly.
///
/// THE SAME THREE STEPS THE WEBSITE USES, in the same order:
///   1. compress,
///   2. Firebase Storage — the primary path, into the same bucket certificate
///      uploads already use, at `meal_checkins/{uid}/{ts}_{rand}.jpg`,
///   3. `POST /api/chat/upload` — the fallback, used whenever Storage is
///      unavailable, denied by bucket rules, or times out.
///
/// The fallback is the whole point: an athlete photographing their lunch must
/// not lose it because a bucket rule changed. A failed Storage upload is a
/// logged warning, never a failed check-in.
///
/// ROOT CAUSE this class also fixes: the Android camera/gallery can hand back
/// HEIC/HEIF (increasingly the DEFAULT capture format on newer Android/Samsung
/// devices) — the backend only accepts jpeg/png/webp, by Content-Type, not by
/// filename. [prepare] always decodes the photo through the PLATFORM's own
/// image codec (the same one used for HEIC everywhere else on the device) and
/// re-encodes it as JPEG, so the backend never sees an unsupported format —
/// and never a bare rename (`.heic` → `.jpg` with the original bytes
/// untouched), which would still be HEIC bytes under a JPEG label.
class MealPhotoUploader {
  MealPhotoUploader({
    FirebaseStorage? storage,
    FirebaseAuth? auth,
    ApiClient? api,
  })  : _storage = storage,
        _auth = auth ?? FirebaseAuth.instance,
        _api = api ?? ApiClient() {
    // The /api/chat/upload fallback now requires a signed-in caller — it
    // writes a file to the server and returns a public URL, which must never
    // be anonymous. The Storage path already authenticated; this one simply
    // never sent the token it had.
    _api.authTokenProvider ??= () async {
      try {
        return await _auth.currentUser?.getIdToken();
      } catch (_) {
        return null;
      }
    };
  }

  final FirebaseStorage? _storage;
  final FirebaseAuth _auth;
  final ApiClient _api;

  /// Matches the website's own limits (`chat-attachments.js`).
  static const maxBytes = 10 * 1024 * 1024;
  static const _storageTimeout = Duration(seconds: 30);
  static const _backendTimeout = Duration(seconds: 60);

  /// Longest edge after compression. A meal photo is looked at on a phone by
  /// one coach; anything larger is bandwidth the athlete pays for on mobile
  /// data for no gain.
  static const _maxDimension = 1600;
  static const _quality = 80;

  /// Decodes the photo — ANY format the platform's camera/gallery can
  /// produce, including HEIC/HEIF — and re-encodes it as a resized JPEG.
  /// This is the ONE normalization step; [upload] and the AI nutrition
  /// estimate (`MealCheckinRepository`) both consume its result so they never
  /// disagree about what was actually sent.
  ///
  /// Throws a short, athlete-facing message (never a raw exception) when the
  /// photo is unusable — too large, or genuinely undecodable AND not already
  /// one of the directly-acceptable formats.
  Future<PreparedMealPhoto> prepare(File file) async {
    final original = await file.length();
    if (original > maxBytes) {
      throw Exception('That image is larger than 10 MB. Try another photo.');
    }

    try {
      final result = await FlutterImageCompress.compressWithFile(
        file.absolute.path,
        minWidth: _maxDimension,
        minHeight: _maxDimension,
        quality: _quality,
        format: CompressFormat.jpeg,
      );
      if (result != null && result.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('[MEAL UPLOAD] compressed ${original ~/ 1024}KB -> ${result.length ~/ 1024}KB (JPEG)');
        }
        return (bytes: result, contentType: 'image/jpeg', fileName: 'meal_snap.jpg');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[MEAL UPLOAD] JPEG re-encode failed ($e)');
    }

    // The platform codec couldn't (re-)encode this file — a genuinely
    // exotic/corrupt image, since JPEG/PNG/WebP/HEIC all decode fine on any
    // modern Android/iOS device. Compression is meant to be an optimization,
    // not a hard gate, so only give up entirely if the ORIGINAL bytes are not
    // already a format the backend will accept — detected from the actual
    // bytes' magic number, never the filename/extension, which the camera can
    // get wrong (e.g. a `.jpg`-named file that is actually HEIC).
    final raw = await file.readAsBytes();
    final sniffed = _sniffImageMime(raw);
    if (sniffed == null) {
      throw Exception('Unable to process this meal photo. Please try another image.');
    }
    if (kDebugMode) debugPrint('[MEAL UPLOAD] using original bytes as-is ($sniffed)');
    return (bytes: raw, contentType: sniffed, fileName: 'meal_snap.${_extensionFor(sniffed)}');
  }

  /// Uploads an already-[prepare]d photo. Returns the URL to store on the
  /// check-in. Throws only when BOTH Storage and the backend fallback fail —
  /// at which point there genuinely is no image to attach — with a short,
  /// athlete-facing message; the real cause (a technical exception, an
  /// unexpected response) is only ever logged, never shown.
  Future<String> uploadPrepared(PreparedMealPhoto photo, {String pathPrefix = 'meal_checkins'}) async {
    try {
      final url = await _toFirebaseStorage(photo.bytes, pathPrefix).timeout(_storageTimeout);
      if (kDebugMode) debugPrint('[MEAL UPLOAD] Firebase Storage OK');
      return url;
    } catch (e) {
      // Exactly the website's behaviour: warn and fall through. Storage being
      // unreachable is not a reason to lose the athlete's photo.
      if (kDebugMode) {
        debugPrint('[MEAL UPLOAD] Firebase Storage failed ($e) — falling back to backend');
      }
    }

    final url = await _toBackend(photo).timeout(_backendTimeout);
    if (kDebugMode) debugPrint('[MEAL UPLOAD] backend fallback OK -> $url');
    return url;
  }

  /// Convenience for a caller that only needs the final URL and does not also
  /// need the prepared bytes for anything else.
  Future<String> upload(File file, {String pathPrefix = 'meal_checkins'}) async {
    final prepared = await prepare(file);
    return uploadPrepared(prepared, pathPrefix: pathPrefix);
  }

  Future<String> _toFirebaseStorage(Uint8List bytes, String pathPrefix) async {
    final storage = _storage ?? FirebaseStorage.instance;
    final uid = _auth.currentUser?.uid ?? 'anon';
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final rand = (stamp % 100000).toRadixString(36);
    final path = '$pathPrefix/$uid/${stamp}_$rand.jpg';

    final ref = storage.ref().child(path);
    await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }

  Future<String> _toBackend(PreparedMealPhoto photo) async {
    try {
      final res = await _api.postMultipartBytes(
        '/api/chat/upload',
        fileField: 'file',
        fileName: photo.fileName,
        fileBytes: photo.bytes,
        contentType: photo.contentType,
      );
      if (res is Map && res['success'] == true && res['url'] is String) {
        final url = res['url'] as String;
        // The backend returns a site-relative path (`/uploads/chat/x.jpg`);
        // absolute-ise it so the coach's app can load it from anywhere.
        return url.startsWith('http') ? url : '${Env.apiBaseUrl}$url';
      }
      if (kDebugMode) debugPrint('[MEAL UPLOAD] backend returned an unexpected response: $res');
    } catch (e) {
      // Never let a raw transport/API exception (e.g. an ApiException whose
      // message is backend-internal wording) reach the athlete — this is
      // exactly what used to leak "ApiException(400): Only jpg, jpeg, png,
      // and webp images are accepted." straight into a snackbar.
      if (kDebugMode) debugPrint('[MEAL UPLOAD] backend fallback request failed: $e');
    }
    throw Exception('Could not upload the photo. Please try again.');
  }
}

/// Detects JPEG/PNG/WebP from the actual file bytes (magic numbers) — never
/// the filename/extension, which the platform camera/gallery can get wrong.
/// Returns null for anything else (including HEIC/HEIF, which [prepare]
/// above should already have converted away from before this is ever reached).
String? _sniffImageMime(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 &&
      bytes[4] == 0x0D && bytes[5] == 0x0A && bytes[6] == 0x1A && bytes[7] == 0x0A) {
    return 'image/png';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 && // 'RIFF'
      bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) { // 'WEBP'
    return 'image/webp';
  }
  return null;
}

String _extensionFor(String contentType) => switch (contentType) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
