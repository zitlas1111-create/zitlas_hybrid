import 'local_storage_service.dart';

/// Mirrors `ZitlasAccountGuard` in `frontend/assets/js/firebase-config.js`.
///
/// Local cache is per-device, not per-user. If a second ZITLAS account signs
/// in on the same device, every user-scoped cached key must be purged before
/// any feature reads (or re-uploads) it — otherwise account B silently
/// inherits account A's cached plans/goal/membership/wallet data. This was a
/// real cross-account data-leak bug on web; the fix ports 1:1.
class AccountGuard {
  AccountGuard._();
  static final AccountGuard instance = AccountGuard._();

  static const _ownerKey = 'zitlas_cache_owner_uid';

  /// Device/UI-scoped keys that legitimately survive an account switch —
  /// the web app's `KEEP_KEYS` list, plus the device-state keys that only
  /// exist on mobile.
  ///
  /// The step keys below describe THE HANDSET, not the person: whether this
  /// phone has been granted OS permissions, and where the hardware counter
  /// stood at the last read. Purging them on sign-out revoked nothing (the OS
  /// grant survives) but made ZITLAS believe tracking had never been enabled,
  /// so the athlete was asked to "Enable" again after every sign-out and the
  /// sensor re-anchored from scratch. Step HISTORY is deliberately NOT here —
  /// that is personal data, it is purged on an account switch, and it is
  /// re-hydrated from Firestore for whoever signs in.
  static const _deviceKeys = {
    // Describes the hardware, not the person. Was previously purged on
    // every logout, which silently defeated its own "stable per-install"
    // contract: push registration minted a fresh id each time (leaving the
    // old device_tokens row orphaned), and presence would do the same with
    // its session documents.
    'zitlas_device_id',
    'zitlas_theme',
    'zitlas_language',
    'zitlas_trial_mode',
    'zitlas_step_perm_state',
    'zitlas_remember',
    'zitlas_step_tracking_enabled',
    'zitlas_step_permission_denied',
    'zitlas_step_baseline',
    'zitlas_step_last_read_at',
    // NOTE: 'zitlas_notification_prompted' and 'zitlas_notification_prefs'
    // used to be listed here and were WRONG to be. They describe a PERSON's
    // choices, not the device: an athlete who muted meal reminders handed
    // that mute to the next account signed in on the same phone, and an
    // expert's (irrelevant) athlete-category settings persisted back to an
    // athlete. They are now purged with the rest of the account cache.
  };

  LocalStorageService get _storage => LocalStorageService.instance;

  /// Claims the local cache for [uid]. Purges every non-device-scoped key
  /// first if the cache belonged to a different account. No-ops (adopts
  /// without purging) on a fresh device with no recorded owner yet. Call
  /// this the moment sign-in/sign-up/session-restore resolves a uid.
  Future<void> beginSession(String uid) async {
    final owner = _storage.getString(_ownerKey);
    if (owner == uid) return;
    if (owner != null && owner != uid) {
      await _storage.clearExcept(_deviceKeys);
    }
    await _storage.setString(_ownerKey, uid);
  }

  /// Full purge on logout — including the owner stamp, releasing the cache
  /// so the next `beginSession` (any uid) adopts without a warning purge.
  Future<void> clearUserCache() async {
    await _storage.clearExcept(_deviceKeys);
  }
}
