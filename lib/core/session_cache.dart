import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Caches the authenticated account + subscription locally so the app opens
/// **offline-first** (no network round-trip needed to enter the app after the
/// first successful sign-in). Cleared on logout.
class SessionCache {
  static final SessionCache _instance = SessionCache._internal();
  factory SessionCache() => _instance;
  SessionCache._internal();

  static const _kAccount = 'cached_account';
  static const _kRemember = 'remember_me';
  static const _kLastBackup = 'last_backup_at';
  static const _kLastOnlineValidation = 'last_online_validation_at';

  Future<void> saveAccount(Map<String, dynamic> account) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kAccount, jsonEncode(account));
  }

  Future<Map<String, dynamic>?> readAccount() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kAccount);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> setRememberMe(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kRemember, value);
  }

  Future<bool> getRememberMe() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kRemember) ?? true;
  }

  Future<void> setLastBackupAt(String iso) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLastBackup, iso);
  }

  Future<String?> getLastBackupAt() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kLastBackup);
  }

  /// Timestamp (ISO-8601) of the last successful **online** session validation
  /// (`/auth/me` confirmed the session is still valid). Used to auto-logout a
  /// device that has been offline beyond the allowed threshold.
  Future<void> setLastOnlineValidationAt(String iso) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLastOnlineValidation, iso);
  }

  Future<DateTime?> getLastOnlineValidationAt() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kLastOnlineValidation);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// Clears cached account + per-account backup timestamp + last online
  /// validation timestamp on logout (keeps language / printer settings
  /// untouched).
  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kAccount);
    await p.remove(_kLastBackup);
    await p.remove(_kLastOnlineValidation);
  }
}
