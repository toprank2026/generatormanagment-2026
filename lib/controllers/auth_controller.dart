import 'package:get/get.dart';
import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/core/logger.dart';
import 'package:generatormanagment/core/secure_store.dart';
import 'package:generatormanagment/core/session_cache.dart';
import 'package:generatormanagment/data/models/account.dart';
import 'package:generatormanagment/data/models/user_model.dart';
import 'package:generatormanagment/data/repositories/auth_repository.dart';

/// Authentication + session state.
///
/// Offline-first: after the first successful online sign-in the account is
/// cached locally, so the app opens offline. The server is only contacted for
/// register / sign-in and (when online) a best-effort `/auth/me` refresh that
/// re-checks subscription + block status. Only a 401/403 ends the session.
class AuthController extends GetxController {
  final AuthRepository _auth = AuthRepository();
  final SessionCache _cache = SessionCache();
  final SecureStore _store = SecureStore();
  final ConnectivityService _net = ConnectivityService();

  final isLoggedIn = false.obs;
  final isLoading = true.obs;
  final isSyncing = false.obs;

  /// Server account (source of truth when online).
  final Rxn<Account> account = Rxn<Account>();

  /// Backward-compatible local "User" view of the account so existing screens
  /// that read `auth.currentUser.value?.id` / `.role` keep working.
  final Rxn<User> currentUser = Rxn<User>();

  /// True only when the server (while online) said the subscription is not
  /// active or the account is blocked. Drives the plan-selection gate. We do
  /// NOT block offline users on a stale state.
  final subscriptionBlocked = false.obs;

  Subscription? get subscription => account.value?.subscription;
  bool get hasActiveSubscription => account.value?.subscription.isActive ?? false;
  bool get isAdmin =>
      (currentUser.value?.role ?? account.value?.role ?? '') == 'admin';

  @override
  void onInit() {
    super.onInit();
    bootstrap();
  }

  /// Restore the cached session, then (if online) refresh from the server.
  Future<void> bootstrap() async {
    isLoading.value = true;
    try {
      final token = await _store.readToken();
      final cached = await _cache.readAccount();
      if (token != null && token.isNotEmpty && cached != null) {
        _setAccount(Account.fromJson(cached), online: false);
        isLoggedIn.value = true;
        if (await _net.isOnline()) {
          await _refreshFromServer();
        }
      } else {
        isLoggedIn.value = false;
      }
    } catch (e) {
      Log.e('bootstrap failed', e);
    } finally {
      isLoading.value = false;
    }
    update();
  }

  Future<void> _refreshFromServer() async {
    try {
      isSyncing.value = true;
      final acc = await _auth.me();
      await _cache.saveAccount(acc.toJson());
      _setAccount(acc, online: true);
    } on ApiException catch (e) {
      // Only an explicit auth rejection ends the session. Network errors keep
      // the cached (offline) session alive.
      if (e.isAuthError) {
        await logout();
      } else {
        Log.w('me() refresh skipped: ${e.message}');
      }
    } catch (e) {
      Log.e('me() refresh failed', e);
    } finally {
      isSyncing.value = false;
      update();
    }
  }

  void _setAccount(Account acc, {required bool online}) {
    account.value = acc;
    currentUser.value = User(
      id: acc.id,
      username: acc.username,
      passwordHash: '',
      role: acc.role,
    );
    if (acc.blocked) {
      subscriptionBlocked.value = true;
    } else if (online) {
      subscriptionBlocked.value = !acc.subscription.isActive;
    }
    // Offline: keep prior gate state (default false → allow offline use).
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    try {
      if (!await _net.isOnline()) {
        return {
          'success': false,
          'message': 'No internet connection. Sign-in requires being online.',
        };
      }
      final result = await _auth.login(username: username, password: password);
      await _cache.saveAccount(result.account.toJson());
      _setAccount(result.account, online: true);
      isLoggedIn.value = true;
      update();
      return {'success': true};
    } on ApiException catch (e) {
      return {'success': false, 'statusCode': e.statusCode, 'message': e.message};
    } catch (e) {
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  Future<Map<String, dynamic>> register({
    required String name,
    String? phone,
    required String username,
    required String password,
  }) async {
    try {
      if (!await _net.isOnline()) {
        return {
          'success': false,
          'message': 'No internet connection. Sign-up requires being online.',
        };
      }
      final result = await _auth.register(
        name: name,
        phone: phone,
        username: username,
        password: password,
      );
      await _cache.saveAccount(result.account.toJson());
      _setAccount(result.account, online: true);
      isLoggedIn.value = true;
      update();
      return {'success': true};
    } on ApiException catch (e) {
      return {'success': false, 'statusCode': e.statusCode, 'message': e.message};
    } catch (e) {
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  /// Re-check subscription/plan status (online only). Used after requesting a
  /// plan and on returning online.
  Future<void> refreshSubscription() async {
    if (await _net.isOnline()) await _refreshFromServer();
  }

  // --- Backward-compatible setup helpers (now backed by the cloud account) ---

  /// Old first-run "create admin" path now registers an account on the backend.
  Future<void> createInitialAdmin(String username, String password) async {
    await register(name: username, username: username, password: password);
  }

  /// Accounts now live on the backend, so there is no local "first user" check.
  Future<bool> hasAnyUser() async => false;

  Future<void> logout() async {
    await _auth.logout();
    await _cache.clear();
    isLoggedIn.value = false;
    account.value = null;
    currentUser.value = null;
    subscriptionBlocked.value = false;
    update();
  }
}
