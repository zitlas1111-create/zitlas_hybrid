import 'local_storage_service.dart';

/// The stable per-install identifier for THIS device.
///
/// Shared deliberately: push registration and presence both need to
/// recognise the same physical device, and minting one id per subsystem
/// would mean a phone that appears twice in `device_tokens` and leaves an
/// orphaned presence session behind on every logout.
///
/// Survives logout and account switches — see `AccountGuard._deviceKeys`,
/// which preserves this key precisely because it describes the hardware,
/// not the person holding it.
abstract final class DeviceIdentity {
  static const key = 'zitlas_device_id';

  /// Reads the existing id, or mints and persists one on first call.
  static Future<String> get() async {
    final existing = LocalStorageService.instance.getString(key);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = 'dev_${DateTime.now().millisecondsSinceEpoch}_'
        '${identityHashCode(DeviceIdentity).toRadixString(36)}';
    await LocalStorageService.instance.setString(key, id);
    return id;
  }
}
