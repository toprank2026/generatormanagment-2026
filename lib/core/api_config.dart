/// Central configuration for the accounts-only backend.
///
/// Defaults to the live production server. Override the base URL at build/run
/// time for local dev, e.g.:
///   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:4000   (Android emulator)
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.99:4000 (LAN device)
///
/// IMPORTANT: scheme + host only — no trailing slash and no `/api` (every path
/// constant below already starts with `/api/...`, joined via
/// `Uri.parse('${ApiConfig.baseUrl}$path')`).
class ApiConfig {
  ApiConfig._();

  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://generator.ecommerceflash.com',
  );

  static const Duration timeout = Duration(seconds: 20);

  // --- Auth ---
  static const String register = '/api/auth/register';
  static const String login = '/api/auth/login';
  static const String me = '/api/auth/me';
  // v23 §4.2: move an account onto this device (evicts the LRU binding).
  static const String recoverDevice = '/api/auth/recover-device';
  // v42 item 4: owner forgot-password. Both are PUBLIC (no JWT — the owner is
  // locked out) and rate-limited server-side; the reset is only ever applied by
  // a super admin in the control panel, so the app just files the request and
  // polls its status.
  static const String forgotPassword = '/api/auth/forgot-password';
  static const String forgotPasswordStatus = '/api/auth/forgot-password/status';

  // --- Accountant sub-accounts (owner creates/manages; R8) ---
  static const String accountants = '/api/account/accountants';
  static String accountantById(String id) => '/api/account/accountants/$id';

  // --- Branch sub-accounts (Flash item 8: owner creates a branch login) ---
  static const String branches = '/api/account/branches';

  // --- Accountant wallet (v11): server-authoritative balance (all-time). ---
  static const String accountWallet = '/api/account/wallet';

  // --- v20: owner/admin self-edit of their own login/account details. ---
  static const String accountProfile = '/api/account/profile';

  // --- Subscription ---
  static const String plans = '/api/subscription/plans';
  static const String subscription = '/api/subscription';
  static const String subscriptionRequest = '/api/subscription/request';

  // --- Device binding ---
  static const String devices = '/api/device';
  static const String deviceBind = '/api/device/bind';
  static String deviceById(String id) => '/api/device/$id';

  // --- Cloud backup ---
  static const String backup = '/api/backup';
  static String backupById(String id) => '/api/backup/$id';
  static String backupDownload(String id) => '/api/backup/$id/download';

  // --- Offline sync (push local business data to the server mirror) ---
  static const String syncPush = '/api/sync/push';
  static const String syncPull = '/api/sync/pull';
}
