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

  /// v23 §4.2: recover this account onto THIS device — same request shape as
  /// [login] (credentials + device fingerprint), but hits `recover-device`,
  /// which evicts the least-recently-seen binding to admit this one.
  Future<AuthResult> recoverDevice({
    required String username,
    required String password,
  }) async {
    final device = await _device.collect();
    final res = await _api.post(
      ApiConfig.recoverDevice,
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

  /// v20: owner/admin edits their OWN account (username / password / name /
  /// phone / generatorName). The backend bumps tokenVersion on a password change
  /// and returns a FRESH token so THIS device's session survives — [_parseAuth]
  /// writes it. Only the provided (non-null) fields are sent. Throws
  /// [ApiException] on 409 (USERNAME_TAKEN / PHONE_TAKEN) or other failures.
  Future<AuthResult> updateProfile({
    String? username,
    String? password,
    String? currentPassword, // v23 §3.2: sent only when changing the password
    String? name,
    String? phone,
    String? generatorName,
    String? contactPhone, // v30 F3: pass "" to clear, a value to set, null to skip
  }) async {
    final body = <String, dynamic>{};
    if (username != null) body['username'] = username;
    if (password != null && password.isNotEmpty) {
      body['password'] = password;
      if (currentPassword != null) body['currentPassword'] = currentPassword;
    }
    if (name != null) body['name'] = name;
    if (phone != null) body['phone'] = phone;
    if (generatorName != null) body['generatorName'] = generatorName;
    if (contactPhone != null) body['contactPhone'] = contactPhone;
    final res = await _api.put(ApiConfig.accountProfile, body: body);
    return _parseAuth(res);
  }

  /// R8: register an accountant as a real BACKEND sub-account tied to a branch.
  /// The owner/admin (current session) calls this; the server creates a User
  /// with role 'accountant', owner = caller, the given branch + permissions, and
  /// stores [localId] so business rows attribute to the same app-side id.
  /// Returns the created accountant map. Throws [ApiException] on failure
  /// (e.g. 409 USERNAME_TAKEN, or offline → network error).
  Future<Map<String, dynamic>> createAccountant({
    required String localId,
    required String name,
    required String username,
    required String password,
    required String branchId,
    Iterable<String> permissions = const [],
  }) async {
    final res = await _api.post(
      ApiConfig.accountants,
      body: {
        'localId': localId,
        'name': name,
        // v11 (item 6): accountants log in by phone (username == phone). Send
        // both so the backend stores the phone and derives username from it.
        'username': username,
        'phone': username,
        'password': password,
        'branchId': branchId,
        'permissions': permissions.toList(),
      },
    );
    final map = (res as Map).cast<String, dynamic>();
    final acc = map['accountant'] ?? map;
    return (acc as Map).cast<String, dynamic>();
  }

  /// Flash item 8: owner creates a BRANCH login account (generator name + phone
  /// + password). The branch is a backend owner-role account linked to this
  /// owner (parentOwner) with its own isolated mirror; it logs in via the normal
  /// login screen. Returns the created branch map. Throws [ApiException]
  /// (409 PHONE_TAKEN, 403 SUB_BRANCH_FORBIDDEN/FORBIDDEN, 400 VALIDATION).
  Future<Map<String, dynamic>> createBranch({
    required String generatorName,
    required String phone,
    required String password,
    String? planCode, // v13: branch is an independent generator with its OWN plan
  }) async {
    final res = await _api.post(
      ApiConfig.branches,
      body: {
        'generatorName': generatorName,
        'phone': phone,
        'password': password,
        if (planCode != null && planCode.isNotEmpty) 'planCode': planCode,
      },
    );
    final map = (res as Map).cast<String, dynamic>();
    final b = map['branch'] ?? map;
    return (b as Map).cast<String, dynamic>();
  }

  /// Flash item 8: list this owner's branch accounts.
  Future<List<Map<String, dynamic>>> listBranches() async {
    final res = await _api.get(ApiConfig.branches);
    final map = (res as Map).cast<String, dynamic>();
    final list = (map['branches'] as List?) ?? const [];
    return list
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList(growable: false);
  }

  /// R8: update a backend accountant sub-account (by the app-side [localId]).
  /// Used to disable (active:false), rename, re-scope branch/permissions, or
  /// reset the password ON THE SERVER so a revoke/disable actually takes effect
  /// (the local-only path could not stop a backend login). Throws [ApiException].
  Future<void> updateAccountant(
    String localId, {
    String? name,
    Iterable<String>? permissions,
    String? branchId,
    bool? active,
    String? password,
    String? ownerPassword, // v23 §3.3: sent only when resetting the password
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (permissions != null) body['permissions'] = permissions.toList();
    if (branchId != null) body['branchId'] = branchId;
    if (active != null) body['active'] = active;
    if (password != null && password.isNotEmpty) {
      body['password'] = password;
      if (ownerPassword != null) body['ownerPassword'] = ownerPassword;
    }
    await _api.put(ApiConfig.accountantById(localId), body: body);
  }

  /// R8: delete the backend accountant sub-account (by the app-side [localId]),
  /// so a deleted accountant can no longer log in. Throws [ApiException].
  Future<void> deleteAccountant(String localId) async {
    await _api.delete(ApiConfig.accountantById(localId));
  }

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
