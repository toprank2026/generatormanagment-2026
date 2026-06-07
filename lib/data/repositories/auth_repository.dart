import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/api_config.dart';
import 'package:generatormanagment/core/device_info_service.dart';
import 'package:generatormanagment/core/secure_store.dart';
import 'package:generatormanagment/data/models/account.dart';

/// Result of a successful register/login: the JWT (already persisted) + account.
class AuthResult {
  final String token;
  final Account account;
  AuthResult(this.token, this.account);
}

/// The ONLY repository that authenticates against the backend. All other
/// repositories deal with local SQLite. Sends the device fingerprint on
/// register/login so the backend can bind the account to its device(s).
class AuthRepository {
  final ApiClient _api = ApiClient();
  final SecureStore _store = SecureStore();
  final DeviceInfoService _device = DeviceInfoService();

  Future<AuthResult> register({
    required String name,
    String? generatorName,
    String? phone,
    required String username,
    required String password,
  }) async {
    final device = await _device.collect();
    final res = await _api.post(
      ApiConfig.register,
      auth: false,
      body: {
        'name': name,
        'generatorName': generatorName,
        'phone': phone,
        'username': username,
        'password': password,
        'device': device,
      },
    );
    return _parseAuth(res);
  }

  Future<AuthResult> login({
    required String username,
    required String password,
  }) async {
    final device = await _device.collect();
    final res = await _api.post(
      ApiConfig.login,
      auth: false,
      body: {
        'username': username,
        'password': password,
        'device': device,
      },
    );
    return _parseAuth(res);
  }

  /// Re-fetches the account (used for offline-first re-validation). A thrown
  /// [ApiException] with `isAuthError` is the only thing that ends the session.
  Future<Account> me() async {
    final res = await _api.get(ApiConfig.me);
    return Account.fromJson(_accountJson(res));
  }

  Future<void> logout() => _store.clearToken();

  Future<AuthResult> _parseAuth(dynamic res) async {
    final map = (res as Map).cast<String, dynamic>();
    final token = (map['token'] ?? map['accessToken'] ?? '').toString();
    if (token.isNotEmpty) await _store.writeToken(token);
    return AuthResult(token, Account.fromJson(_accountJson(map)));
  }

  Map<String, dynamic> _accountJson(dynamic res) {
    final map = (res as Map).cast<String, dynamic>();
    final account = map['account'] ?? map['user'] ?? map;
    return (account as Map).cast<String, dynamic>();
  }
}
