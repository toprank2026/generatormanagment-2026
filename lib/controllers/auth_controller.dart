import 'dart:async';

import 'package:get/get.dart';
import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/core/logger.dart';
import 'package:generatormanagment/core/secure_store.dart';
import 'package:generatormanagment/core/session_cache.dart';
import 'package:generatormanagment/core/device_rebind.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/month_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/account.dart';
import 'package:generatormanagment/data/models/user_model.dart';
import 'package:generatormanagment/data/repositories/auth_repository.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';
import 'package:generatormanagment/views/widgets/sync_progress_overlay.dart';

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
  final AccountantRepository _accountants = AccountantRepository();

  /// SharedPreferences keys for the local acting-user layer.
  static const String _kActingUserId = 'acting_user_id';
  static const String _kOwnerPwdHash = 'owner_pwd_hash';

  /// v22 item 7: which account's data the local DB belongs to (EFFECTIVE owner
  /// id — an accountant maps to its owner). Compared on every login so a
  /// different account never inherits/pushes another account's local rows.
  static const String _kDbOwnerAccountId = 'db_owner_account_id';

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

  /// The ACTING local user — the owner by default, or an accountant sub-user
  /// after an offline profile-switch. This is the identity that drives
  /// permission gating, per-accountant data scoping, and record attribution.
  /// Existing screens that read `auth.currentUser.value?.id` / `.role` keep
  /// working — they now reflect whoever is acting.
  final Rxn<User> currentUser = Rxn<User>();

  /// The owner identity derived from the cloud account (always the admin),
  /// kept separate so we can switch back to it without a network call.
  final Rxn<User> ownerUser = Rxn<User>();

  /// True when an accountant (not the owner/admin) is currently acting.
  bool get isAccountant => currentUser.value?.role == 'accountant';

  /// Whether the acting user may perform [perm] (see Perm). The owner/admin can
  /// do everything; an accountant only what was granted to them. (Recording
  /// payments + printing are always allowed and are not gated by this.)
  bool can(String perm) =>
      isAdmin || (currentUser.value?.permissions.contains(perm) ?? false);

  /// The acting accountant's id used to scope reads/writes: `null` for the
  /// owner/admin (sees & owns everything), the accountant's id otherwise.
  String? get scopeAccountantId => isAdmin ? null : currentUser.value?.id;

  /// Display name of the acting user (for printed invoices / UI).
  String get actingUserName => currentUser.value?.displayName ?? '';

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

  /// Per-plan capability flags resolved live from the active plan (defaults to
  /// TRUE when absent, preserving capabilities for plans predating the flags).
  /// Reactive: they read the Rxn account, so callers inside Obx stay reactive.
  bool get canSync => account.value?.subscription.syncEnabled ?? true;
  bool get canBackup => account.value?.subscription.backupEnabled ?? true;
  bool get canOwnerPanel => account.value?.subscription.ownerPanelEnabled ?? true;
  /// Multi-Branch is an opt-in upgrade → defaults FALSE when there is no plan.
  /// Gates creating/switching branches beyond the Main Branch.
  bool get canMultiBranch =>
      account.value?.subscription.multiBranchEnabled ?? false;
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
        await _restoreActingUser();
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
    if (acc.role == 'accountant') {
      // R8: a backend accountant sub-account logged in via the Login screen.
      // The acting identity uses the app-side localId (so business rows
      // attribute to the same accountant_id the owner sees) and the granted
      // permissions; there is no separate owner identity on this device.
      final actor = User(
        id: (acc.localId != null && acc.localId!.isNotEmpty)
            ? acc.localId!
            : acc.id,
        username: acc.username,
        passwordHash: '',
        role: 'accountant',
        name: acc.name,
        permissions: acc.permissions.toSet(),
      );
      ownerUser.value = actor;
      currentUser.value = actor;
    } else {
      final owner = User(
        id: acc.id,
        username: acc.username,
        passwordHash: '',
        role: acc.role,
        name: acc.name,
      );
      ownerUser.value = owner;
      // Preserve the acting user across background refreshes (an accountant
      // mid-session must not be silently switched back to the owner). Only set
      // it when nothing is acting yet, or when the current actor IS the owner.
      final cur = currentUser.value;
      if (cur == null || cur.id == acc.id) {
        currentUser.value = owner;
      }
    }
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
      return await _completeSignIn(result, username, password);
    } on ApiException catch (e) {
      // v23 §4.1: expose the error code so the login screen can distinguish
      // DEVICE_LIMIT from a blocked account (and offer device recovery).
      return {
        'success': false,
        'statusCode': e.statusCode,
        'code': e.code,
        'message': e.message,
      };
    } catch (e) {
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  /// v23 §4.2: move THIS account onto THIS device. Calls the backend
  /// `recover-device` endpoint (evicts the least-recently-seen binding, binds
  /// this device) then completes sign-in exactly like [login]. Owner/admin only
  /// (accountants are device-exempt so they never hit DEVICE_LIMIT).
  Future<Map<String, dynamic>> recoverDevice(
      String username, String password) async {
    try {
      if (!await _net.isOnline()) {
        return {'success': false, 'message': 'no_internet_sign_in'.tr};
      }
      final result =
          await _auth.recoverDevice(username: username, password: password);
      return await _completeSignIn(result, username, password);
    } on ApiException catch (e) {
      return {
        'success': false,
        'statusCode': e.statusCode,
        'code': e.code,
        'message': e.message,
      };
    } catch (e) {
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  /// Shared post-authentication tail for [login] and [recoverDevice]: caches the
  /// account, applies it, runs the cross-account residue guard BEFORE marking
  /// the session live (v22 §7 ordering), then pulls the mirror + re-establishes
  /// branches. Returns {success:true}, or the cancel map when the residue guard
  /// is declined.
  Future<Map<String, dynamic>> _completeSignIn(
      AuthResult result, String username, String password) async {
    await _cache.saveAccount(result.account.toJson());
    // Fresh sign-in always resets the acting user (then _setAccount re-sets it
    // to the owner or, for a backend accountant, the accountant actor).
    currentUser.value = null;
    _setAccount(result.account, online: true);
    await _clearActingUser();
    // Owner-password hash (for the offline owner profile-switch) is only
    // meaningful for an owner/admin session, not an accountant one.
    if (result.account.role != 'accountant') {
      await _persistOwnerCredential(username, password);
    }
    await _cache.setLastOnlineValidationAt(DateTime.now().toIso8601String());
    // v22 item 7: cross-account residue guard — MUST run BEFORE the session is
    // marked live (isLoggedIn=true). While the guard's warning dialog is open,
    // SyncController's heartbeat/connectivity auto-push gates on _loggedIn:
    // flipping it first would let the OLD account's outbox push into the NEW
    // account's mirror behind the dialog (cross-account leak + permanent loss),
    // and RootHandler would flash MainScreen with the old data. Keyed on the
    // EFFECTIVE owner (an accountant shares its owner's mirror).
    final String effOwner = result.account.role == 'accountant'
        ? (result.account.ownerId ?? result.account.id)
        : result.account.id;
    if (!await _guardCrossAccountResidue(effOwner)) {
      // v23 §4.4: the server already bound this device during _auth.login — a
      // cancelled sign-in must release that slot (best-effort, online here).
      try {
        await DeviceRebind.apply(rebind: false);
      } catch (_) {}
      await logout();
      return {'success': false, 'message': 'login_cancelled'.tr};
    }
    isLoggedIn.value = true;
    logoutReason.value = null; // clear any prior "you were signed out" warning
    update();
    // R8: an accountant starts with no local data on its own device — pull the
    // owner's mirror (backend scopes by effective owner) and activate the
    // accountant's branch so the app opens on its data.
    // P4: an owner/admin login also auto-fetches data from the backend (after a
    // logout wipe the local DB is empty, so this restores it).
    if (result.account.role == 'accountant') {
      await _onAccountantLoggedIn(result.account);
    } else {
      try {
        if (Get.isRegistered<SyncController>()) {
          await Get.find<SyncController>().pull(silent: true);
        }
      } catch (e) {
        Log.w('owner post-login pull skipped: $e');
      }
      // v22 item 7: resetForLogout cleared the in-memory branch list (and pull's
      // reload doesn't cover BranchController) — re-establish branches from the
      // freshly-pulled DB and activate Main, like the accountant path.
      try {
        if (Get.isRegistered<BranchController>()) {
          await Get.find<BranchController>()
              .reloadAndActivate(DbHelper.kMainBranchId);
        }
      } catch (e) {
        Log.w('post-login branch reload skipped: $e');
      }
    }
    return {'success': true};
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
      // v22 item 7: same cross-account residue guard as login — a brand-new
      // account must never inherit (or push) another account's local rows.
      if (!await _guardCrossAccountResidue(result.account.id)) {
        await logout();
        return {'success': false, 'message': 'login_cancelled'.tr};
      }
      await _cache.setLastOnlineValidationAt(DateTime.now().toIso8601String());
      isLoggedIn.value = true;
      update();
      // A residue wipe removes the branches table's Main row — re-establish it
      // (ensureMain) and the in-memory branch list for the fresh account.
      try {
        if (Get.isRegistered<BranchController>()) {
          await Get.find<BranchController>()
              .reloadAndActivate(DbHelper.kMainBranchId);
        }
      } catch (e) {
        Log.w('post-register branch reload skipped: $e');
      }
      return {'success': true};
    } on ApiException catch (e) {
      return {'success': false, 'statusCode': e.statusCode, 'message': e.message};
    } catch (e) {
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  /// v20: owner/admin edits their OWN account (username/password/name/phone/
  /// generatorName). Online-only. The backend returns a FRESH token (so this
  /// device's session survives a password change) + the updated account, which
  /// we cache + apply so the UI reflects it immediately. Returns
  /// {success:bool, statusCode?, message?}.
  Future<Map<String, dynamic>> updateProfile({
    String? username,
    String? password,
    String? currentPassword, // v23 §3.2: required by the backend when password set
    String? name,
    String? phone,
    String? generatorName,
  }) async {
    try {
      if (!await _net.isOnline()) {
        return {'success': false, 'message': 'online_only'.tr};
      }
      final result = await _auth.updateProfile(
        username: username,
        password: password,
        currentPassword: currentPassword,
        name: name,
        phone: phone,
        generatorName: generatorName,
      );
      await _cache.saveAccount(result.account.toJson());
      _setAccount(result.account, online: true);
      // v20: a password change rotates the OFFLINE owner-credential hash too, so
      // the offline gates that compare against it (encrypted-backup restore,
      // the pre-switch/pre-wipe confirm, switchToOwner) accept the NEW password
      // instead of the old one.
      if (password != null && password.isNotEmpty) {
        await _persistOwnerCredential(result.account.username, password);
      }
      update();
      return {'success': true};
    } on ApiException catch (e) {
      return {
        'success': false,
        'statusCode': e.statusCode,
        'code': e.code, // v23 §3.2: lets the UI show WRONG_PASSWORD specifically
        'message': e.message,
      };
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
      // Refresh the in-memory account so the dashboard reflects any change,
      // preserving the acting user (see _setAccount). The subscription gate is
      // re-derived just below from _sessionProblemReason.
      _setAccount(acc, online: true);
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

  /// v22 item 7: cross-account residue guard. When this device's local DB
  /// still belongs to a DIFFERENT effective owner, the residue must be wiped
  /// BEFORE any push/pull (a stale outbox would otherwise push the old
  /// account's rows into the new account's mirror). If that residue contains
  /// UNSYNCED rows, the user is warned first and may cancel — returns false on
  /// cancel (the caller aborts the sign-in), true when it's safe to continue.
  /// Best-effort on internal errors (never blocks a normal sign-in).
  Future<bool> _guardCrossAccountResidue(String effOwner) async {
    SharedPreferences prefs;
    String? prevOwner;
    try {
      prefs = await SharedPreferences.getInstance();
      prevOwner = prefs.getString(_kDbOwnerAccountId);
    } catch (e) {
      // Best-effort: can't read the stamp — never block a normal sign-in.
      Log.w('cross-account residue guard skipped: $e');
      return true;
    }
    if (prevOwner != null &&
        prevOwner != effOwner &&
        Get.isRegistered<SyncController>()) {
      final sync = Get.find<SyncController>();
      try {
        await sync.refreshPending();
      } catch (_) {}
      // Unsynced rows from the other account would be permanently lost —
      // warn and allow the user to back out.
      if (sync.pendingCount.value > 0) {
        final ok = await Get.defaultDialog<bool>(
          title: 'warning'.tr,
          middleText: 'cross_account_wipe_warning'.tr,
          textConfirm: 'continue'.tr,
          textCancel: 'cancel'.tr,
          barrierDismissible: false,
          onConfirm: () => Get.back(result: true),
          onCancel: () {},
        );
        if (ok != true) return false;
      }
      // Fail CLOSED: if the wipe itself fails, signing in would push/merge
      // another account's rows into this account's mirror — abort instead.
      try {
        await sync.deleteAllLocalData();
      } catch (e) {
        Log.w('cross-account residue wipe failed: $e');
        return false;
      }
    }
    try {
      await prefs.setString(_kDbOwnerAccountId, effOwner);
    } catch (_) {/* stamp is best-effort; worst case the next login re-checks */}
    return true;
  }

  /// Ends the session. [reason] is a translation key for the warning to show on
  /// the login screen (set by [recheckSession]); leave it null for a normal
  /// user-initiated logout so no warning is shown.
  Future<void> logout({String? reason, bool wipeLocal = false}) async {
    // P4: on a user-initiated logout, delete local business data first (push any
    // unsynced changes up first so they aren't lost). [wipeLocal] is false for
    // INVOLUNTARY logouts (offline-too-long / session-expired — the user may be
    // offline and unable to re-pull) and for the settings restore flows (which
    // logout specifically to reload freshly-restored data). The next login
    // auto-pulls the account's data fresh from the backend.
    if (wipeLocal && Get.isRegistered<SyncController>()) {
      final sync = Get.find<SyncController>();
      final bool online = canSync && await _net.isOnline();
      // Flash v17 — DATA-LOSS GUARD (ALL roles: owner/admin/accountant): NEVER
      // wipe local data while UNSYNCED records remain (rows in sync_outbox, i.e.
      // is_synced=0/pending_sync). This runs BEFORE any delete or session
      // teardown, and ONLY when the plan ENABLES sync (canSync): on a sync-
      // DISABLED ("offline-only") plan the outbox can never reach the server, so
      // blocking on it would lock the user out of logout forever — those accounts
      // fall through to the offline confirm+wipe below (unrecoverable, so it asks
      // first, exactly as before v17).
      if (canSync) {
        // 1) A sync is currently running → temporarily disable logout until it
        //    completes (don't race the wipe against an in-flight push/pull).
        if (sync.isSyncing.value || sync.isPulling.value) {
          Get.snackbar('logout'.tr, 'logout_sync_running'.tr,
              snackPosition: SnackPosition.BOTTOM);
          return;
        }
        // 2) ONLINE → push pending first (upload ONLY; never deletes) so a normal
        //    online logout still completes with no manual step.
        if (online) {
          SyncProgress.show('sync_uploading'.tr);
          try {
            // showOverlay:false — we own the overlay here.
            await sync.syncNow(silent: true, showOverlay: false);
          } catch (_) {} finally {
            SyncProgress.hide();
          }
        }
        // 3) Re-read the REAL outbox AFTER the push attempt (not a stale snapshot).
        try {
          await sync.refreshPending();
        } catch (_) {}
        // 4) STILL unsynced (offline, or the push failed) → BLOCK the logout and
        //    keep ALL local data intact. The user must sync before logging out.
        if (sync.pendingCount.value > 0) {
          await Get.defaultDialog<void>(
            title: 'warning'.tr,
            middleText: 'logout_blocked_unsynced'.tr,
            textConfirm: 'ok'.tr,
            onConfirm: () => Get.back(),
          );
          return; // do NOT delete local data or end the session
        }
      }
      // 5) Sync-disabled plan, or no unsynced data → confirm, then safely wipe
      //    ALL local data (every table). v18 item 1: the same confirm also covers
      //    DEVICE UNBINDING (this device is linked to the account; it is unbound
      //    so another account can use it — the next login re-runs binding).
      final ok = await Get.defaultDialog<bool>(
        title: 'logout'.tr,
        middleText:
            '${online ? 'logout_confirm'.tr : 'logout_offline_wipe_msg'.tr}\n\n${'device_rebind_confirm'.tr}',
        textConfirm: online ? 'logout'.tr : 'delete_local_data'.tr,
        textCancel: 'cancel'.tr,
        onConfirm: () => Get.back(result: true),
        onCancel: () {},
      );
      if (ok != true) return; // cancel → abort the logout entirely
      SyncProgress.show('logging_out'.tr);
      try {
        // v18 item 1: unbind this device + clear local install-id (no immediate
        // rebind — the next login's fresh-registration flow rebinds). Online-
        // gated + best-effort, so it never blocks the wipe/logout.
        await DeviceRebind.apply(rebind: false);
        await sync.deleteAllLocalData();
      } catch (e) {
        Log.w('logout local wipe failed: $e');
      } finally {
        SyncProgress.hide();
      }
    }
    await _auth.logout();
    await _cache.clear();
    await _clearActingUser();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kOwnerPwdHash);
    // End the session FIRST: the resets below fire ever() workers (month/branch)
    // whose listeners gate on the session — with isLoggedIn already false,
    // SyncController's _monthWorker can't launch a zombie (token-less) pull
    // that would block the next login's post-login pull.
    isLoggedIn.value = false;
    account.value = null;
    currentUser.value = null;
    ownerUser.value = null;
    subscriptionBlocked.value = false;
    // v22 item 7: reset session-scoped state so the NEXT account starts clean
    // in the same app run — active branch (pref + in-memory), selected month,
    // and the previous session's sync markers. Best-effort: never blocks logout.
    try {
      if (Get.isRegistered<BranchController>()) {
        await Get.find<BranchController>().resetForLogout();
      }
      if (Get.isRegistered<MonthController>()) {
        Get.find<MonthController>().resetToCurrentMonth();
      }
      if (Get.isRegistered<SyncController>()) {
        await Get.find<SyncController>().resetSessionState();
      }
    } catch (e) {
      Log.w('logout state reset skipped: $e');
    }
    logoutReason.value = reason;
    update();
  }

  /// R8: after a backend accountant signs in, pull the owner's data (the server
  /// scopes the mirror to the effective owner) and activate the accountant's
  /// branch. Best-effort: a failed pull leaves the account signed in (data
  /// loads on the next successful sync).
  Future<void> _onAccountantLoggedIn(Account acc) async {
    try {
      if (Get.isRegistered<SyncController>()) {
        await Get.find<SyncController>().pull(silent: true);
      }
      if (Get.isRegistered<BranchController>()) {
        await Get.find<BranchController>().reloadAndActivate(acc.branchId);
      }
    } catch (e) {
      Log.w('accountant post-login pull skipped: $e');
    }
  }

  // --- Acting-user (local accountant) layer -------------------------------

  /// Sign in as an accountant sub-user — a purely LOCAL, offline credential
  /// check (no network). On success the accountant becomes the acting user and
  /// the selection is persisted across relaunches. Returns false on bad
  /// credentials or a disabled accountant.
  /// v13: verify the owner password WITHOUT mutating the session — used to gate
  /// an account switch BEFORE the destructive local wipe (a wrong password must
  /// not wipe data). No captured hash (legacy session) => allow.
  Future<bool> verifyOwnerPassword(String password) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kOwnerPwdHash);
    if (stored == null || stored.isEmpty) return true;
    return AccountantRepository.hashPassword(password) == stored;
  }

  /// v13: verify accountant credentials WITHOUT switching/wiping — local hash
  /// first, else (online) a backend login check. Used to gate the switch wipe.
  Future<bool> verifyAccountantPassword(String username, String password) async {
    final local = await _accountants.authenticate(username.trim(), password);
    if (local != null) return true;
    if (await _net.isOnline()) {
      try {
        final r = await _auth.login(username: username.trim(), password: password);
        return r.account.role == 'accountant';
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  Future<bool> loginAsAccountant(String username, String password) async {
    final user = await _accountants.authenticate(username.trim(), password);
    if (user != null) {
      currentUser.value = user;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kActingUserId, user.id);
      update();
      return true;
    }
    // v13 fix: the local credential (users.password_hash) is wiped by a hard
    // logout and is NOT synced, so the offline profile-switch can't find it after
    // logout+login. Fall back to a REAL backend login (the server holds the
    // password + inherits the owner plan), which works with no local credential.
    if (await _net.isOnline()) {
      final res = await login(username.trim(), password);
      return res['success'] == true && isAccountant;
    }
    return false;
  }

  /// Switch back to the owner/admin. Requires the owner's password, verified
  /// offline against the hash captured at sign-in. If no hash was captured
  /// (sessions predating this feature) the switch is allowed.
  Future<bool> switchToOwner(String password) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kOwnerPwdHash);
    if (stored != null && stored.isNotEmpty) {
      if (AccountantRepository.hashPassword(password) != stored) return false;
    }
    currentUser.value = ownerUser.value;
    await _clearActingUser();
    update();
    return true;
  }

  Future<void> _persistOwnerCredential(String username, String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kOwnerPwdHash, AccountantRepository.hashPassword(password));
  }

  Future<void> _clearActingUser() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kActingUserId);
  }

  /// On launch, restore a previously-selected accountant as the acting user
  /// (offline-safe: the identity comes from the synced `accountants` table).
  Future<void> _restoreActingUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_kActingUserId);
      if (id == null || id.isEmpty || id == account.value?.id) return;
      final a = await _accountants.getById(id);
      if (a != null && a.active) {
        currentUser.value = User(
          id: a.id,
          username: a.username,
          passwordHash: '',
          role: 'accountant',
          name: a.name,
          permissions: a.permissions,
        );
      }
    } catch (e) {
      Log.w('restore acting user skipped: $e');
    }
  }
}
