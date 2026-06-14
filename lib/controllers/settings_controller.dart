import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/core/session_cache.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/account.dart';
import 'package:generatormanagment/data/models/accountant_model.dart';
import 'package:generatormanagment/data/repositories/backup_repository.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';
import 'package:generatormanagment/utils/printer_prefs.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

class SettingsController extends GetxController {
  final AccountantRepository _accountantRepo = AccountantRepository();
  final DbHelper _dbHelper = DbHelper();
  final BackupRepository _backupRepo = BackupRepository();
  final AuthController auth = Get.find();

  /// Owner-managed accountant sub-users (synced identity rows).
  var accountants = <Accountant>[].obs;
  var isLoading = false.obs;

  // --- Cloud backup ---
  var cloudBackups = <BackupEntry>[].obs;
  var isCloudBusy = false.obs;
  var lastCloudBackupAt = Rxn<String>();

  // Printer Settings
  var printerName = "".obs;
  var printerAddress = "".obs;
  // Thermal paper width in mm (58 or 80); default 58.
  var paperWidthMm = PrinterPrefs.defaultWidthMm.obs;

  // Persistence Keys
  static const String _keyLang = 'lang_code';
  static const String _keyPrinterName = 'printer_name';
  static const String _keyPrinterAddress = 'printer_address';

  Future<void> changeLanguage(String langCode) async {
    final locale = langCode == 'ar'
        ? const Locale('ar', 'AR')
        : const Locale('en', 'US');

    Get.updateLocale(locale);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLang, langCode);
    update();
  }

  Future<Locale> loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final String? langCode = prefs.getString(_keyLang);

    // Default to Arabic when no language has been chosen yet.
    if (langCode == 'en') {
      return const Locale('en', 'US');
    }
    return const Locale('ar', 'AR');
  }

  @override
  void onInit() {
    super.onInit();
    // Reload the accountant list whenever the acting user changes, so the
    // owner always sees the current set (and the count) after a switch.
    ever(auth.currentUser, (_) {
      if (auth.isAdmin) {
        loadAccountants();
      } else {
        accountants.clear();
      }
    });
  }

  @override
  void onReady() {
    super.onReady();
    loadPrinterSettings();
    _loadLastBackupAt();
    if (auth.isAdmin) {
      loadAccountants();
    }
  }

  Future<void> _loadLastBackupAt() async {
    lastCloudBackupAt.value = await SessionCache().getLastBackupAt();
  }

  Future<void> loadPrinterSettings() async {
    final prefs = await SharedPreferences.getInstance();
    printerName.value = prefs.getString(_keyPrinterName) ?? "";
    printerAddress.value = prefs.getString(_keyPrinterAddress) ?? "";
    paperWidthMm.value = await PrinterPrefs.load();
    update();
  }

  Future<void> savePrinterSettings(String name, String address) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPrinterName, name);
    await prefs.setString(_keyPrinterAddress, address);
    printerName.value = name;
    printerAddress.value = address;
    update();
  }

  /// Persists the thermal paper width (58 or 80 mm) and refreshes the cache
  /// read by the print services.
  Future<void> savePaperWidth(int mm) async {
    await PrinterPrefs.setWidth(mm);
    paperWidthMm.value = PrinterPrefs.widthMm;
    update();
  }

  // --------------------------------------------------------------------------
  // ACCOUNTANTS (owner-managed sub-users). Creating an accountant writes BOTH
  // the local credential row (for offline login) and the synced identity row
  // (visible to the admin panel) via AccountantRepository.
  // --------------------------------------------------------------------------

  /// Load the full accountant list (small, owner-managed set — no pagination).
  Future<void> loadAccountants() async {
    isLoading.value = true;
    try {
      accountants.assignAll(await _accountantRepo.getAll());
    } catch (e) {
      Get.snackbar('error'.tr, "${'accountants'.tr}: $e");
    } finally {
      isLoading.value = false;
    }
    update();
  }

  /// Create a new accountant (credential + synced identity rows).
  Future<void> createAccountant(
      String name, String username, String password) async {
    try {
      await _accountantRepo.create(
        id: const Uuid().v4(),
        username: username,
        name: name,
        password: password,
      );
      await loadAccountants();
      Get.snackbar('success'.tr, 'add_accountant'.tr);
    } catch (e) {
      Get.snackbar('error'.tr, "${'add_accountant'.tr}: $e");
    }
    update();
  }

  /// Update an accountant's name / active state and optionally reset password.
  Future<void> updateAccountant(
    String id, {
    String? name,
    bool? active,
    String? newPassword,
  }) async {
    try {
      await _accountantRepo.update(
        id: id,
        name: name,
        active: active,
        newPassword: newPassword,
      );
      await loadAccountants();
      Get.snackbar('success'.tr, 'edit_accountant'.tr);
    } catch (e) {
      Get.snackbar('error'.tr, "${'edit_accountant'.tr}: $e");
    }
    update();
  }

  /// Delete an accountant (both rows).
  Future<void> deleteAccountant(String id) async {
    if (id == auth.currentUser.value?.id) {
      Get.snackbar('error'.tr, 'cannot_delete_self'.tr);
      return;
    }
    try {
      await _accountantRepo.delete(id);
      accountants.removeWhere((a) => a.id == id);
    } catch (e) {
      Get.snackbar('error'.tr, "${'delete'.tr}: $e");
    }
    update();
  }

  Future<void> exportData() async {
    isLoading.value = true;
    try {
      String dbPath = await _dbHelper.getDbPath();
      File dbFile = File(dbPath);

      if (!dbFile.existsSync()) {
        Get.snackbar('error'.tr, 'db_file_not_found'.tr);
        return;
      }

      // Create a temporary file with a timestamped name
      final tempDir = await getTemporaryDirectory();
      String fileName =
          'flash_backup_${DateTime.now().year}${DateTime.now().month}${DateTime.now().day}_${DateTime.now().hour}${DateTime.now().minute}.db';
      final tempFile = File(p.join(tempDir.path, fileName));

      // Copy db to temp file
      await dbFile.copy(tempFile.path);

      // Share the file
      await Share.shareXFiles(
        [XFile(tempFile.path)],
        text:
            'Flash Database Backup ${DateTime.now().toString().split('.')[0]}',
      );
    } catch (e) {
      Get.snackbar('error'.tr, "${'export_failed'.tr}: $e");
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> importData() async {
    try {
      // Pick a file
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        dialogTitle: 'select_backup_file'.tr,
      ); // Any extension, as we can't strictly enforce .db on all android versions reliably or user might have renamed it

      if (result != null && result.files.single.path != null) {
        String path = result.files.single.path!;
        File file = File(path);

        // Basic check if it likely is a db file or just try to open it
        if (!path.toLowerCase().endsWith('.db') &&
            !path.toLowerCase().endsWith('.sqlite')) {
          // We can warn but maybe proceed if user insists? For now let's just warn
          Get.defaultDialog(
            title: 'warning'.tr,
            middleText: 'not_db_file_warning'.tr,
            textConfirm: 'yes_try'.tr,
            textCancel: 'cancel'.tr,
            onConfirm: () {
              Get.back();
              _confirmImportProcess(file);
            },
          );
          return;
        }

        _confirmImportProcess(file);
      }
    } catch (e) {
      Get.snackbar('error'.tr, "${'import_failed'.tr}: $e");
    }
  }

  void _confirmImportProcess(File file) {
    Get.defaultDialog(
      title: 'confirm_restore'.tr,
      middleText: 'import_overwrite_warning'.tr,
      textConfirm: 'restore'.tr,
      textCancel: 'cancel'.tr,
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      onConfirm: () {
        Get.back();
        _performImport(file);
      },
    );
  }

  Future<void> _performImport(File sourceFile) async {
    try {
      isLoading.value = true;
      String dbPath = await _dbHelper.getDbPath();

      // Close DB connection first to release lock
      await _dbHelper.close();

      // Overwrite file
      await sourceFile.copy(dbPath);

      Get.defaultDialog(
        title: 'success'.tr,
        middleText: 'import_success_restart'.tr,
        textConfirm: 'logout_restart'.tr,
        barrierDismissible: false,
        onConfirm: () {
          auth.logout();
          Get.back();
          // Optionally exit(0) or just let logout handle it.
          // Logout usually redirects to login, which is fine.
        },
      );
    } catch (e) {
      Get.snackbar('error'.tr, "${'import_execution_failed'.tr}: $e");
      // Try to reopen db if failed?
    } finally {
      isLoading.value = false;
    }
  }

  // --------------------------------------------------------------------------
  // CLOUD BACKUP (server-side DB snapshots) — distinct from local export/import
  // --------------------------------------------------------------------------

  Future<void> refreshCloudBackups() async {
    // Backup is a per-plan capability — never hit the (gated) backup API when
    // the active plan disables it (the backend would 403 FEATURE_DISABLED).
    if (!auth.canBackup) return;
    // Silent no-op when offline (this runs on screen open; the UI shows an
    // 'online_only' hint instead of nagging with a snackbar each time).
    if (!await ConnectivityService().isOnline()) return;
    isCloudBusy.value = true;
    try {
      cloudBackups.assignAll(await _backupRepo.list());
    } catch (e) {
      Get.snackbar('error'.tr, "${'cloud_backup'.tr}: $e");
    } finally {
      isCloudBusy.value = false;
    }
    update();
  }

  Future<void> uploadCloudBackup({String? note}) async {
    // Backup is a per-plan capability. The Settings tile reaching this screen is
    // already hidden when backup is off, but guard here too (defense in depth)
    // so NO path can fire a backup network call or show a backup toast on a plan
    // without backup — matching refreshCloudBackups + the sync side. Silent
    // return: a disabled feature must never notify.
    if (!auth.canBackup) return;
    final online = await ConnectivityService().isOnline();
    if (!online) {
      Get.snackbar('cloud_backup'.tr, 'online_only'.tr);
      return;
    }

    isCloudBusy.value = true;
    try {
      await _backupRepo.upload(note: note);
      final iso = DateTime.now().toIso8601String();
      await SessionCache().setLastBackupAt(iso);
      lastCloudBackupAt.value = iso;
      Get.snackbar('cloud_backup'.tr, 'backup_uploaded'.tr);
      await refreshCloudBackups();
    } catch (e) {
      Get.snackbar('error'.tr, "${'cloud_backup'.tr}: $e");
    } finally {
      isCloudBusy.value = false;
    }
    update();
  }

  Future<void> deleteCloudBackup(String id) async {
    if (!auth.canBackup) return; // per-plan capability guard (see uploadCloudBackup)
    if (!await ConnectivityService().isOnline()) {
      Get.snackbar('cloud_backup'.tr, 'online_only'.tr);
      return;
    }
    isCloudBusy.value = true;
    try {
      await _backupRepo.delete(id);
      cloudBackups.removeWhere((b) => b.id == id);
    } catch (e) {
      Get.snackbar('error'.tr, "${'cloud_backup'.tr}: $e");
    } finally {
      isCloudBusy.value = false;
    }
    update();
  }

  void restoreCloudBackup(String id) {
    if (!auth.canBackup) return; // per-plan capability guard (see uploadCloudBackup)
    Get.defaultDialog(
      title: 'cloud_backup'.tr,
      middleText: 'restore_overwrite_warning'.tr,
      textConfirm: 'restore'.tr,
      textCancel: 'cancel'.tr,
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      onConfirm: () {
        Get.back();
        _performCloudRestore(id);
      },
    );
  }

  Future<void> _performCloudRestore(String id) async {
    if (!auth.canBackup) return; // per-plan capability guard (see uploadCloudBackup)
    if (!await ConnectivityService().isOnline()) {
      Get.snackbar('cloud_backup'.tr, 'online_only'.tr);
      return;
    }
    isCloudBusy.value = true;
    try {
      await _backupRepo.restore(id);
      Get.snackbar('cloud_backup'.tr, 'backup_restored'.tr);
      // Force a restart-like reload so the freshly restored DB is picked up.
      Get.find<AuthController>().logout();
    } catch (e) {
      Get.snackbar('error'.tr, "${'cloud_backup'.tr}: $e");
    } finally {
      isCloudBusy.value = false;
    }
    update();
  }
}
