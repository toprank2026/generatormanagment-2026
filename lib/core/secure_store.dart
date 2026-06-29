import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:generatormanagment/core/logger.dart';

/// Encrypted at-rest storage for the JWT and the stable install-id.
///
/// The install-id is generated once and intentionally **survives logout** so it
/// keeps identifying the physical install for device binding / anti-abuse.
///
/// v18 RESILIENCE: on Android the EncryptedSharedPreferences keystore can become
/// undecryptable (`AEADBadTagException` / "Signature/MAC verification failed")
/// after reinstalls or key rotation — every read/write then THROWS. That left a
/// freshly-issued login token unwritten, so the next sync sent a stale token and
/// the server replied 401 ("session expired"/"sync not available"). Every method
/// below now self-heals: on a keystore error it wipes the corrupt store and
/// retries the write, so the login token always sticks (the OS-stable deviceId
/// keeps the device recognised after the wipe).
class SecureStore {
  static final SecureStore _instance = SecureStore._internal();
  factory SecureStore() => _instance;
  SecureStore._internal();

  static const _kToken = 'auth_token';
  static const _kInstallId = 'install_id';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Wipe the (corrupt) store so it regenerates cleanly on the next write.
  Future<void> _resetOnError(Object e) async {
    Log.w('SecureStore: keystore error, resetting store: $e');
    try {
      await _storage.deleteAll();
    } catch (_) {/* nothing more we can do */}
  }

  Future<String?> readToken() async {
    try {
      return await _storage.read(key: _kToken);
    } catch (e) {
      await _resetOnError(e);
      return null;
    }
  }

  /// Persist the JWT. If the keystore is corrupt the first write throws — wipe
  /// the store and retry once so the token IS saved (critical: a lost token =
  /// the next request goes unauthenticated → 401).
  Future<void> writeToken(String token) async {
    try {
      await _storage.write(key: _kToken, value: token);
    } catch (e) {
      await _resetOnError(e);
      try {
        await _storage.write(key: _kToken, value: token);
      } catch (_) {/* best-effort */}
    }
  }

  Future<void> clearToken() async {
    try {
      await _storage.delete(key: _kToken);
    } catch (e) {
      await _resetOnError(e);
    }
  }

  /// v18 item 1: clear the persistent install-id so the next [installId] call
  /// generates a fresh one (used by the device unbind/rebind flow to "clear the
  /// local device binding data"). The OS-stable deviceId is unaffected.
  Future<void> clearInstallId() async {
    try {
      await _storage.delete(key: _kInstallId);
    } catch (e) {
      await _resetOnError(e);
    }
  }

  /// Returns the persistent install-id, generating + storing one on first call.
  Future<String> installId() async {
    String? value;
    try {
      value = await _storage.read(key: _kInstallId);
    } catch (e) {
      await _resetOnError(e);
      value = null;
    }
    if (value == null || value.isEmpty) {
      value = const Uuid().v4();
      try {
        await _storage.write(key: _kInstallId, value: value);
      } catch (_) {/* best-effort: a transient id is still usable this session */}
    }
    return value;
  }
}
