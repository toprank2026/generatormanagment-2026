import 'dart:async';

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

  // The two durations below can be overridden with --dart-define for testing
  // (e.g. --dart-define=RECHECK_SECONDS=30); production builds use the
  // defaults (15 minutes / 3 days).
  static const int _recheckSeconds =
      int.fromEnvironment('RECHECK_SECONDS', defaultValue: 900);
  static const int _offlineLogoutSeconds =
      int.fromEnvironment('OFFLINE_LOGOUT_SECONDS', defaultValue: 259200); // 3 days

  /// How often we re-validate the session against the server while online.
  static const _recheckInterval = Duration(seconds: _recheckSeconds);

  /// If the device stays offline (no successful online validation) longer than
  /// this, the session is ended and the user must sign in again. Keeps the
  /// offline-first contract for brief blips while still bounding offline use.
  static const _offlineLogoutThreshold = Duration(seconds: _offlineLogoutSeconds);

  /// Periodic online re-check timer (cancelled in [onClose]).
  Timer? _recheckTimer;

  /// Guards against overlapping re-checks (periodic tick vs. pull-to-refresh).
  bool _recheckInFlight = false;

  /// Server account (source of truth when online).
  final Rxn<Account> account = Rxn<Account>();

  /// Backward-compatible local "User" view of the account so existing screens
  /// that read `auth.currentUser.value?.id` / `.role` keep working.
  final Rxn<User> currentUser = Rxn<User>();

  /// True only when the server (while online) said the subscription is not
  /// active or the account is blocked. Drives the plan-selection gate. We do
  /// NOT block offline users on a stale state.
  final subscriptionBlocked = false.obs;

  /// When a session ends because of a server-side change (account blocked,
  /// subscription expired, or plan changed to a non-active state) this holds the
  /// translation key for the warning shown on the login screen. It is `null` for
  /// a normal user-initiated logout, so no warning is shown then.
  final logoutReason = RxnString();

  Subscription? get subscription => account.value?.subscription;
  bool get hasActiveSubscription => account.value?.subscription.isActive ?? false;
  /// In-app management rights (create/edit/delete boards, circuits, subscribers,
  /// staff). The account holder is either the business `owner` or an `admin`;
  /// both manage their own data. (Local 'accountant' staff are restricted.)
  bool get isAdmin {
    // Read the observable FIRST so this getter stays reactive when used inside
    // Obx (the DEV_ADMIN test override must not short-circuit the .value read).
    final role = currentUser.value?.role ?? account.value?.role ?? '';
    return role == 'admin' ||
        role == 'owner' ||
        const bool.fromEnvironment('DEV_ADMIN');
  }

  @override
  void onInit() {
    super.onInit();
    bootstrap();
    _startPeriodicRecheck();
  }

  @override
  void onClose() {
    _recheckTimer?.cancel();
    _recheckTimer = null;
    super.onClose();
  }

  /// Starts a periodic online re-validation. On each tick, if online we run the
  /// shared [recheckSession] (which signs out + sets [logoutReason] on
  /// blocked/expired); if offline we enforce the offline-too-long rule.
  void _startPeriodicRecheck() {
    _recheckTimer?.cancel();
    _recheckTimer = Timer.periodic(_recheckInterval, (_) => _onRecheckTick());
  }

  Future<void> _onRecheckTick() async {
    if (!isLoggedIn.value) return;
    if (await _net.isOnline()) {
      await guardedRecheck();
    } else {
      await _enforceOfflineLimit();
    }
  }

  /// Runs [recheckSession] unless one is already in flight (e.g. a concurrent
  /// pull-to-refresh or nav-bar tap), so callers never overlap. Safe to
  /// fire-and-forget: offline / network errors leave the session untouched.
  Future<bool> guardedRecheck() async {
    if (_recheckInFlight) return true;
    _recheckInFlight = true;
    try {
      return await recheckSession();
    } finally {
      _recheckInFlight = false;
    }
  }

  /// Auto-logout if the device has been offline (no successful online
  /// validation) longer than [_offlineLogoutThreshold]. Initialises the
  /// timestamp on first use so a brand-new session is never logged out, and a
  /// brief network blip never trips the rule.
  Future<void> _enforceOfflineLimit() async {
    if (!isLoggedIn.value) return;
    final last = await _cache.getLastOnlineValidationAt();
    if (last == null) {
      // No baseline yet (fresh session / first run) — set it to now so we don't
      // immediately sign out, then start counting from here.
      await _cache.setLastOnlineValidationAt(DateTime.now().toIso8601String());
      return;
    }
    if (DateTime.now().difference(last) > _offlineLogoutThreshold) {
      await logout(reason: 'offline_too_long');
    }
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
        } else {
          // Offline launch: enforce the offline-too-long auto-logout rule.
          await _enforceOfflineLimit();
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
      // Successful online validation → reset the offline-too-long baseline.
      await _cache.setLastOnlineValidationAt(DateTime.now().toIso8601String());
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
          'message': 'no_internet_sign_in'.tr,
        };
      }
      final result = await _auth.login(username: username, password: password);
      await _cache.saveAccount(result.account.toJson());
      _setAccount(result.account, online: true);
      await _cache.setLastOnlineValidationAt(DateTime.now().toIso8601String());
      isLoggedIn.value = true;
      logoutReason.value = null; // clear any prior "you were signed out" warning
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
    String? generatorName,
    String? phone,
    required String username,
    required String password,
  }) async {
    try {
      if (!await _net.isOnline()) {
        return {
          'success': false,
          'message': 'no_internet_sign_up'.tr,
        };
      }
      final result = await _auth.register(
        name: name,
        generatorName: generatorName,
        phone: phone,
        username: username,
        password: password,
      );
      await _cache.saveAccount(result.account.toJson());
      _setAccount(result.account, online: true);
      await _cache.setLastOnlineValidationAt(DateTime.now().toIso8601String());
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

  /// Pull-to-refresh / periodic / nav-switch online re-validation. Re-fetches
  /// the account and signs the user out to the login screen with a suitable
  /// warning (`logoutReason`) when the account is **blocked** or a
  /// **previously-active** subscription is no longer active (expired / changed
  /// / revoked). When the subscription was *already* inactive (user is on the
  /// plan-selection screen awaiting approval or renewing) it only keeps the
  /// subscription gate set — logging out there would kick a user who is
  /// legitimately waiting for admin approval. A benign plan change that is
  /// still active just refreshes the banner. Offline or transient network
  /// errors keep the session untouched.
  ///
  /// Returns `true` if the session is still valid (caller may keep going),
  /// `false` if the user was signed out.
  Future<bool> recheckSession() async {
    if (!await _net.isOnline()) return true; // only check "at home with internet"
    try {
      isSyncing.value = true;
      final wasActive = account.value?.subscription.isActive ?? false;
      final acc = await _auth.me();
      await _cache.saveAccount(acc.toJson());
      // Refresh the in-memory account so the dashboard reflects any change.
      account.value = acc;
      currentUser.value = User(
        id: acc.id,
        username: acc.username,
        passwordHash: '',
        role: acc.role,
      );
      final reason = _sessionProblemReason(acc);
      if (reason != null) {
        final isBlocked = acc.blocked;
        if (isBlocked || wasActive) {
          // Blocked, or an active plan was revoked/expired mid-session →
          // end the session with the warning.
          await logout(reason: reason);
          return false;
        }
        // Subscription was already inactive (none/pending/expired before this
        // check): keep the session and the plan-selection gate so the user can
        // request/renew and the approval poll can let them in.
        subscriptionBlocked.value = true;
        await _cache.setLastOnlineValidationAt(DateTime.now().toIso8601String());
        update();
        return true;
      }
      subscriptionBlocked.value = false; // active again → clear any gate
      // Successful online validation → reset the offline-too-long baseline.
      await _cache.setLastOnlineValidationAt(DateTime.now().toIso8601String());
      update();
      return true;
    } on ApiException catch (e) {
      // A hard auth rejection ends the session; network errors keep it.
      if (e.isAuthError) {
        await logout(
          reason: e.statusCode == 403 ? 'account_disabled' : 'session_expired',
        );
        return false;
      }
      Log.w('recheckSession skipped: ${e.message}');
      return true;
    } catch (e) {
      Log.e('recheckSession failed', e);
      return true;
    } finally {
      isSyncing.value = false;
    }
  }

  /// Maps a refreshed server account to a login-warning key when the session
  /// must end, or `null` when the session is fine.
  String? _sessionProblemReason(Account acc) {
    if (acc.blocked) return 'account_disabled';
    final sub = acc.subscription;
    if (sub.isActive) return null;
    switch (sub.status) {
      case 'expired':
        return 'subscription_expired';
      case 'rejected':
        return 'subscription_rejected';
      case 'pending':
        return 'subscription_pending';
      default:
        return 'subscription_required';
    }
  }

  // --- Backward-compatible setup helpers (now backed by the cloud account) ---

  /// Old first-run "create admin" path now registers an account on the backend.
  Future<void> createInitialAdmin(String username, String password) async {
    await register(name: username, username: username, password: password);
  }

  /// Accounts now live on the backend, so there is no local "first user" check.
  Future<bool> hasAnyUser() async => false;

  /// Ends the session. [reason] is a translation key for the warning to show on
  /// the login screen (set by [recheckSession]); leave it null for a normal
  /// user-initiated logout so no warning is shown.
  Future<void> logout({String? reason}) async {
    await _auth.logout();
    await _cache.clear();
    isLoggedIn.value = false;
    account.value = null;
    currentUser.value = null;
    subscriptionBlocked.value = false;
    logoutReason.value = reason;
    update();
  }
}
