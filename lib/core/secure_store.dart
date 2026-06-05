import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Encrypted at-rest storage for the JWT and the stable install-id.
///
/// The install-id is generated once and intentionally **survives logout** so it
/// keeps identifying the physical install for device binding / anti-abuse.
class SecureStore {
  static final SecureStore _instance = SecureStore._internal();
  factory SecureStore() => _instance;
  SecureStore._internal();

  static const _kToken = 'auth_token';
  static const _kInstallId = 'install_id';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<String?> readToken() => _storage.read(key: _kToken);
  Future<void> writeToken(String token) =>
      _storage.write(key: _kToken, value: token);
  Future<void> clearToken() => _storage.delete(key: _kToken);

  /// Returns the persistent install-id, generating + storing one on first call.
  Future<String> installId() async {
    var value = await _storage.read(key: _kInstallId);
    if (value == null || value.isEmpty) {
      value = const Uuid().v4();
      await _storage.write(key: _kInstallId, value: value);
    }
    return value;
  }
}
