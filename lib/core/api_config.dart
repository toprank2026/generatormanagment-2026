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
    defaultValue: 'https://generator.tikritstore.shop',
  );

  static const Duration timeout = Duration(seconds: 20);

  // --- Auth ---
  static const String register = '/api/auth/register';
  static const String login = '/api/auth/login';
  static const String me = '/api/auth/me';

  // --- Accountant sub-accounts (owner creates/manages; R8) ---
  static const String accountants = '/api/account/accountants';
  static String accountantById(String id) => '/api/account/accountants/$id';

  // --- Branch sub-accounts (Flash item 8: owner creates a branch login) ---
  static const String branches = '/api/account/branches';

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
